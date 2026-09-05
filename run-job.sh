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

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

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
          command: ["sh", "-c", "echo ${command_b64} | base64 -d | sh"]
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
    echo "      volumes:"
    echo "        - name: secret-vol"
    echo "          secret:"
    echo "            secretName: ${SECRET_VOLUME%%:*}"
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

succeeded=$(kube get job "$job_name" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
if [ -n "$succeeded" ] && [ "$succeeded" -gt 0 ] 2>/dev/null; then
  exit 0
fi

echo "Job $job_name did not succeed" >&2
exit 1
