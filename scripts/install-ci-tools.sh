#!/usr/bin/env bash
set -euo pipefail

# Installs actionlint, shellcheck, and bats into $RUNNER_TEMP/bin and adds
# it to $GITHUB_PATH for the rest of the job. None of these are present
# on the runner image by default.

mkdir -p "$RUNNER_TEMP/bin"

command -v xz >/dev/null || { sudo apt-get update && sudo apt-get install -y xz-utils; }

curl -sfL "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz" \
  | tar -xz -C "$RUNNER_TEMP/bin" actionlint

curl -sfL "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz" \
  | tar -xJ -C "$RUNNER_TEMP" shellcheck-v0.11.0/shellcheck
mv "$RUNNER_TEMP/shellcheck-v0.11.0/shellcheck" "$RUNNER_TEMP/bin/shellcheck"

curl -sfL "https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz" -o /tmp/bats.tar.gz
mkdir -p "$RUNNER_TEMP/bats-core"
tar -xzf /tmp/bats.tar.gz -C "$RUNNER_TEMP/bats-core" --strip-components=1
"$RUNNER_TEMP/bats-core/install.sh" "$RUNNER_TEMP/bats-install"
ln -s "$RUNNER_TEMP/bats-install/bin/bats" "$RUNNER_TEMP/bin/bats"

chmod +x "$RUNNER_TEMP/bin/"*
echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
