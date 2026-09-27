#!/bin/bash
set -euo pipefail

API=https://kubernetes.default.svc
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
RUNNER_TOKEN=/var/run/secrets/kubernetes.io/serviceaccount/token

# Mint a short-lived token for the target job ServiceAccount using this
# pod's own github-runner-workload identity, which is only permitted to
# do that one thing for that one ServiceAccount (see k8s-ci-rbac's
# job-service-account-rbac.yaml). Same mechanism as actions-helm's
# dry-run check, just for a ServiceAccount with real, non-dry-run RBAC.
JOB_TOKEN=$(kubectl --server="$API" --certificate-authority="$CA" \
  --token="$(cat "$RUNNER_TOKEN")" \
  create token "$SERVICE_ACCOUNT" -n "$NAMESPACE" --duration=10m)
echo "::add-mask::$JOB_TOKEN"

kube() {
  kubectl --server="$API" --certificate-authority="$CA" --token="$JOB_TOKEN" "$@"
}

# GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT alone collide when one workflow run
# calls this action more than once (e.g. a kaniko build step followed by
# a separate test step) -- add a random suffix so each invocation gets
# its own Job.
suffix="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
repo="${GITHUB_REPOSITORY##*/}"
job_name="${repo}-${suffix}"
job_name="${job_name:0:52}" # leave room for the pod-template-hash suffix Kubernetes appends

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# kaniko's official image is distroless -- ENTRYPOINT ["/kaniko/executor"],
# no shell at all -- so it can never run a `sh -c` wrapped command.
# SHELL=false skips the shell entirely: COMMAND is split on whitespace
# (safe here since kaniko's own flags never contain spaces) and passed as
# `args:`, letting the image's own ENTRYPOINT run them directly. Every
# other caller (npm/pytest/Playwright) needs real shell semantics
# (&&, cd, multi-statement) and keeps the default SHELL=true path.
if [ "${SHELL_MODE:-true}" = "false" ]; then
  read -ra command_args <<< "$COMMAND"
  command_yaml="args: ["
  first=1
  for arg in "${command_args[@]}"; do
    [ "$first" -eq 0 ] && command_yaml+=", "
    command_yaml+="\"$(yaml_escape "$arg")\""
    first=0
  done
  command_yaml+="]"
else
  # kaniko has no shell/git and builds directly from --context=git://...;
  # other images (e.g. Playwright's) have no such context flag, so give
  # them a git-clone preamble instead. Public repos, no auth needed.
  final_command="$COMMAND"
  if [ -n "${CHECKOUT_REF:-}" ]; then
    final_command="apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && git clone --quiet https://github.com/${GITHUB_REPOSITORY}.git /workspace && cd /workspace && git checkout --quiet ${CHECKOUT_REF} && ${COMMAND}"
  fi
  # Base64-round-trip the command so it never needs YAML/shell escaping,
  # regardless of what quotes/$vars/&&s it contains.
  command_b64=$(printf '%s' "$final_command" | base64 -w0)
  command_yaml="command: [\"sh\", \"-c\", \"echo ${command_b64} | base64 -d | sh\"]"
fi

{
  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${ACTIVE_DEADLINE_SECONDS}
  ttlSecondsAfterFinished: 1800
  template:
    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}
      restartPolicy: Never
      containers:
        - name: job
          image: ${IMAGE}
          ${command_yaml}
YAML

  if [ -n "${ENV_VARS:-}" ]; then
    echo "          env:"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key="${line%%=*}"
      value="${line#*=}"
      printf '            - name: %s\n              value: "%s"\n' "$key" "$(yaml_escape "$value")"
    done <<< "$ENV_VARS"
  fi

  if [ -n "${SECRET_VOLUME:-}" ]; then
    echo "          volumeMounts:"
    echo "            - name: secret-vol"
    echo "              mountPath: ${SECRET_VOLUME#*:}"
  fi

  if [ -n "${NODE_SELECTOR:-}" ]; then
    echo "      nodeSelector:"
    IFS=',' read -ra pairs <<< "$NODE_SELECTOR"
    for pair in "${pairs[@]}"; do
      echo "        ${pair%%=*}: \"$(yaml_escape "${pair#*=}")\""
    done
  fi

  if [ -n "${TOLERATIONS:-}" ]; then
    echo "      tolerations:"
    IFS=',' read -ra pairs <<< "$TOLERATIONS"
    for pair in "${pairs[@]}"; do
      kv="${pair%%:*}"
      effect="${pair#*:}"
      cat <<TOL
        - key: "$(yaml_escape "${kv%%=*}")"
          operator: Equal
          value: "$(yaml_escape "${kv#*=}")"
          effect: "$(yaml_escape "$effect")"
TOL
    done
  fi

  if [ -n "${SECRET_VOLUME:-}" ]; then
    # kaniko's push credential must land at exactly
    # /kaniko/.docker/config.json, but the Secret's data key is
    # ".dockerconfigjson" (the standard key for the dockerconfigjson
    # Secret type -- see zot-pull-secret's ExternalSecret template).
    # Mounted plainly, that key becomes the file's own name, giving
    # .../.dockerconfigjson instead -- remap it via `items` so the
    # mounted file is actually named config.json. This is currently the
    # only thing secret-volume is used for.
    cat <<VOLUMES
      volumes:
        - name: secret-vol
          secret:
            secretName: ${SECRET_VOLUME%%:*}
            items:
              - key: .dockerconfigjson
                path: config.json
VOLUMES
  fi
} > /tmp/job.yaml

# shellcheck disable=SC2329 # invoked indirectly via the trap below
cleanup() {
  kube delete job "$job_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kube apply -f /tmp/job.yaml

# Wait until either the pod leaves Pending, or the Job itself is already
# marked failed (e.g. it can never be scheduled at all -- no free
# arm64+Pi-tainted node -- activeDeadlineSeconds gives up on the *Job* in
# that case, without the pod ever leaving Pending, so checking only the
# pod would hang forever).
pod=""
while true; do
  job_failed=$(kube get job "$job_name" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")
  if [ -n "$job_failed" ] && [ "$job_failed" -gt 0 ] 2>/dev/null; then
    break
  fi
  pod=$(kube get pods -n "$NAMESPACE" -l job-name="$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$pod" ]; then
    phase=$(kube get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ -n "$phase" ] && [ "$phase" != "Pending" ]; then
      break
    fi
  fi
  sleep 2
done

if [ -n "$pod" ]; then
  kube logs -f "$pod" -n "$NAMESPACE" || true
fi

# Block on a live watch for the pod's own container to report terminated,
# rather than polling on a guessed schedule -- kubectl wait resolves the
# instant the apiserver actually reports the change, so there's no
# interval/retry-count to tune. Bounded by the Job's own real deadline
# (Kubernetes itself kills the Job at that point regardless), not some
# separately-guessed shorter budget: a fixed 5-try/120-try poll budget
# (~125s total, a previous fix) was confirmed still insufficient on a
# real run where the image finished building and was actually pushed to
# the registry successfully, but neither the pod's nor the Job's status
# had settled ~3 minutes later -- longer than the guessed budget allowed,
# on this box under load. Any fixed guess can lose the same way; only the
# Job's own deadline is a real bound.
#
# Both `kube wait` calls below used to throw away stderr entirely
# (`>/dev/null 2>&1`). On two real runs this reported a false failure
# ~15-17s after the container had already exited 0 -- not a timeout (the
# real ACTIVE_DEADLINE_SECONDS was 1800, not 15) -- and there was no way
# to tell why, because whatever error `kube wait` actually hit was
# discarded before anyone could see it. Direct reproduction against the
# live cluster ruled out the likelier mechanical causes (the jsonpath
# existence-check on a field that transitions from absent to present
# mid-watch resolves correctly; the same is true when it's already
# present before the watch starts; the kube() wrapper's quoting doesn't
# mangle the --for argument), which points to a transient, not yet
# isolated error from the API server itself. Capture each attempt's
# stderr and exit code instead of discarding them, so the next
# occurrence is diagnosable from the workflow log instead of requiring
# another live investigation like this one.
pod_wait_status=1
pod_wait_stderr=""
if [ -n "$pod" ]; then
  if pod_wait_stderr=$(kube wait pod "$pod" -n "$NAMESPACE" \
      --for=jsonpath='{.status.containerStatuses[0].state.terminated}' \
      --timeout="${ACTIVE_DEADLINE_SECONDS}s" 2>&1 1>/dev/null); then
    pod_wait_status=0
  else
    pod_wait_status=$?
  fi
fi

if [ "$pod_wait_status" -eq 0 ]; then
  exit_code=$(kube get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
  if [ -n "$exit_code" ]; then
    exit "$exit_code"
  fi
  echo "kube wait pod reported the container terminated, but its exit code could not be read back afterward -- falling back to the Job's aggregate status." >&2
fi

# Fallback: the pod's own terminated state was never observed at all
# (e.g. the pod was already reaped before this wait started) -- fall
# back to waiting on the Job's own aggregate status the same way.
job_wait_status=1
job_wait_stderr=""
if job_wait_stderr=$(kube wait job "$job_name" -n "$NAMESPACE" \
    --for=jsonpath='{.status.succeeded}' --timeout="${ACTIVE_DEADLINE_SECONDS}s" 2>&1 1>/dev/null); then
  exit 0
else
  job_wait_status=$?
fi

echo "Job $job_name did not succeed" >&2
echo "kube wait pod: exit=${pod_wait_status} stderr=${pod_wait_stderr:-<empty>}" >&2
echo "kube wait job: exit=${job_wait_status} stderr=${job_wait_stderr:-<empty>}" >&2
exit 1
