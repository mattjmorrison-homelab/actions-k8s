#!/usr/bin/env bats

setup() {
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export SERVICE_ACCOUNT="graph-router-job"
  export NAMESPACE="github-runner"
  export IMAGE="gcr.io/kaniko-project/executor:latest"
  export COMMAND="echo hello"
  export ENV_VARS=""
  export SECRET_VOLUME=""
  export NODE_SELECTOR=""
  export TOLERATIONS=""
  export CHECKOUT_REF=""
  export ACTIVE_DEADLINE_SECONDS="900"
  export SHELL_MODE="true"
  export GITHUB_RUN_ID="123"
  export GITHUB_RUN_ATTEMPT="1"
  export GITHUB_REPOSITORY="mattjmorrison-homelab/graph-router"
  export KUBECTL_APPLY_INPUT_FILE="$BATS_TEST_TMPDIR/job.yaml"
  export KUBECTL_TOKEN_SA_LOG="$BATS_TEST_TMPDIR/token-sa.log"
  export KUBECTL_DELETE_MARKER="$BATS_TEST_TMPDIR/deleted.marker"
  export KUBECTL_LOGS_MARKER="$BATS_TEST_TMPDIR/logs.marker"
  export MOCK_JOB_SUCCEEDED="1"
  export MOCK_POD_NAME="testpod"
  export MOCK_POD_PHASE="Running"
}

decoded_command() {
  grep -o '"echo [A-Za-z0-9+/=]* | base64 -d | sh"' "$KUBECTL_APPLY_INPUT_FILE" \
    | sed -E 's/^"echo ([A-Za-z0-9+/=]*) \| base64 -d \| sh"$/\1/' \
    | base64 -d
}

@test "mints a token for SERVICE_ACCOUNT" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$KUBECTL_TOKEN_SA_LOG")" = "graph-router-job" ]
}

@test "mints the token with a duration scaled to ACTIVE_DEADLINE_SECONDS plus margin, not a fixed guess" {
  export ACTIVE_DEADLINE_SECONDS="1800"
  export KUBECTL_CALL_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--duration=2100s" "$KUBECTL_CALL_LOG"
}

@test "floors the token duration at 600s for a short ACTIVE_DEADLINE_SECONDS" {
  export ACTIVE_DEADLINE_SECONDS="120"
  export KUBECTL_CALL_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--duration=600s" "$KUBECTL_CALL_LOG"
}

@test "masks the minted token in output" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [[ "$output" == *"::add-mask::fake-token"* ]]
}

@test "applies a Job manifest targeting the given image and namespace" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q "image: gcr.io/kaniko-project/executor:latest" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q "namespace: github-runner" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q "serviceAccountName: graph-router-job" "$KUBECTL_APPLY_INPUT_FILE"
}

@test "embeds COMMAND base64-encoded, round-tripping to the original string" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  [ "$(decoded_command)" = "echo hello" ]
}

@test "prepends a git checkout preamble when CHECKOUT_REF is set" {
  export CHECKOUT_REF="abc123"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  local decoded
  decoded="$(decoded_command)"
  [[ "$decoded" == *"git clone --quiet https://github.com/mattjmorrison-homelab/graph-router.git"* ]]
  [[ "$decoded" == *"git checkout --quiet abc123"* ]]
  [[ "$decoded" == *"echo hello"* ]]
}

@test "adds a volumeMounts/volumes section when SECRET_VOLUME is set" {
  export SECRET_VOLUME="zot-pull-secret:/kaniko/.docker"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q "mountPath: /kaniko/.docker" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q "secretName: zot-pull-secret" "$KUBECTL_APPLY_INPUT_FILE"
}

@test "remaps the .dockerconfigjson key to config.json so kaniko finds it" {
  export SECRET_VOLUME="zot-pull-secret:/kaniko/.docker"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q "key: .dockerconfigjson" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q "path: config.json" "$KUBECTL_APPLY_INPUT_FILE"
}

@test "omits volumes section entirely when SECRET_VOLUME is unset" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  ! grep -q "volumeMounts" "$KUBECTL_APPLY_INPUT_FILE"
  ! grep -q "secretName" "$KUBECTL_APPLY_INPUT_FILE"
}

@test "adds nodeSelector and tolerations when set, for the arm64+Pi case" {
  export NODE_SELECTOR="kubernetes.io/arch=arm64"
  export TOLERATIONS="dedicated=pi:NoSchedule"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q 'kubernetes.io/arch: "arm64"' "$KUBECTL_APPLY_INPUT_FILE"
  grep -q 'key: "dedicated"' "$KUBECTL_APPLY_INPUT_FILE"
  grep -q 'value: "pi"' "$KUBECTL_APPLY_INPUT_FILE"
  grep -q 'effect: "NoSchedule"' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "passes COMMAND as a plain args list, no shell, when SHELL_MODE is false" {
  export SHELL_MODE="false"
  export IMAGE="gcr.io/kaniko-project/executor@sha256:abc"
  export COMMAND="/kaniko/executor --context=git://github.com/mattjmorrison-homelab/graph-router.git#deadbeef --dockerfile=Dockerfile --target=release --destination=registry.morrisons.site/graph-router:latest"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  ! grep -q '"sh", "-c"' "$KUBECTL_APPLY_INPUT_FILE"
  ! grep -q "base64 -d" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q 'args: \["/kaniko/executor", "--context=git://github.com/mattjmorrison-homelab/graph-router.git#deadbeef", "--dockerfile=Dockerfile", "--target=release", "--destination=registry.morrisons.site/graph-router:latest"\]' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "adds env vars from newline-separated ENV_VARS" {
  export ENV_VARS=$'CI_COMMIT_SHA=abc123\nOTHER=value'
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  grep -q "name: CI_COMMIT_SHA" "$KUBECTL_APPLY_INPUT_FILE"
  grep -q 'value: "abc123"' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "waits for the pod to leave Pending before streaming logs" {
  export MOCK_PENDING_COUNT="2"
  export MOCK_PENDING_COUNTER_FILE="$BATS_TEST_TMPDIR/pending-count"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake pod logs"* ]]
  [ -f "$KUBECTL_LOGS_MARKER" ]
}

@test "exits 0 and streams logs when the Job succeeds" {
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake pod logs"* ]]
}

@test "exits immediately using the pod's own exit code, without ever needing the Job's aggregate status" {
  export MOCK_POD_EXIT_CODE="0"
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_JOB_FAILED=""
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
}

@test "propagates the pod's own nonzero exit code when the container itself failed" {
  export MOCK_POD_EXIT_CODE="1"
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_JOB_FAILED=""
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 1 ]
}

@test "falls back to polling the Job's aggregate status when the pod's own exit code is never available" {
  export MOCK_POD_EXIT_CODE=""
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
}

@test "exits 1 when the Job fails" {
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_JOB_FAILED="1"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not succeed"* ]]
}

@test "never streams logs when the Job fails before any pod exists (unschedulable)" {
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_JOB_FAILED="1"
  export MOCK_POD_NAME=""
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 1 ]
  [ ! -f "$KUBECTL_LOGS_MARKER" ]
}

@test "always deletes the Job on exit, even on failure" {
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_JOB_FAILED="1"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 1 ]
  [ -f "$KUBECTL_DELETE_MARKER" ]
}

@test "surfaces the real stderr and exit code from both kube wait attempts on failure, instead of discarding them" {
  export MOCK_JOB_SUCCEEDED=""
  export MOCK_POD_WAIT_STDERR="error: timed out waiting for the condition on pods/testpod"
  export MOCK_POD_WAIT_EXIT="1"
  export MOCK_JOB_WAIT_STDERR="error: timed out waiting for the condition on jobs/graph-router-123-1-abcd"
  export MOCK_JOB_WAIT_EXIT="1"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not succeed"* ]]
  [[ "$output" == *"kube wait pod: exit=1 stderr=error: timed out waiting for the condition on pods/testpod"* ]]
  [[ "$output" == *"kube wait job: exit=1 stderr=error: timed out waiting for the condition on jobs/graph-router-123-1-abcd"* ]]
}

@test "falls back to the Job's aggregate status and warns when the pod's terminated state is observed but its exit code can't be read back" {
  export MOCK_POD_TERMINATED="1"
  export MOCK_POD_EXIT_CODE=""
  export MOCK_JOB_SUCCEEDED="1"
  run bash "$BATS_TEST_DIRNAME/../run-job.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"its exit code could not be read back afterward"* ]]
}
