# actions-k8s

A single reusable GitHub Actions composite action: mints a short-lived
token for a per-repo job ServiceAccount, creates a real Kubernetes `Job`
to run a container to completion, streams its logs into the GitHub
Actions UI, and propagates its pass/fail exit code.

This exists because the GitHub Actions self-hosted runners here
(`k8s-github-runner`) are plain `ghcr.io/actions/actions-runner` pods with
no Docker socket, no DinD, no privileged access -- zero ability to build
or run a container of their own. This action is how CI actually builds
images (via kaniko, run inside the Job it creates), runs tests inside
just-built images, and runs browser-based smoke tests -- mirroring how
Woodpecker's own kubernetes backend already ran each pipeline step as its
own pod, before Woodpecker's retirement.

Named for the tool it wraps (`kubectl`/the Kubernetes API), same
reasoning as `actions-helm` and `actions-tofu`.

## The token-mint mechanism

Same indirection `actions-helm`'s dry-run check already uses: the shared
`github-runner-workload` identity never holds real permissions itself --
it only mints a 10-minute token for one specific, narrowly-scoped target
ServiceAccount (via a `token-issuer` Role/RoleBinding restricted by
`resourceNames`), which is what actually creates/deletes the Job. Unlike
every `k8s-ci-rbac` dry-run consumer, this grants **real** `create`/
`delete` of live Jobs, not a `--dry-run=server` wrapper.

Each repo needs one real, pre-declared job ServiceAccount + RBAC before
its CI can call this action -- see
[`k8s-ci-rbac`](https://github.com/mattjmorrison-homelab/k8s-ci-rbac)'s
`jobServiceAccounts` list (e.g. `graph-router-job`).

## Why kaniko instead of a privileged Docker build

Each build/test step is its own real, isolated, one-shot Job pod -- not a
shared, persistent runner -- so a privileged container here would have a
much narrower blast radius than a privileged sidecar on the shared runner
pools would. Kept kaniko anyway: it needs **zero** privileged access,
anywhere, ever, which is worth keeping even though a one-shot privileged
Job would also have been an acceptable narrower alternative. The cost is
kaniko's own build syntax and context-passing mechanism
(`--context=git://github.com/org/repo.git#ref` instead of a local
checkout) -- no `checkout-ref` needed for kaniko steps, since that flag
fetches its own context directly.

## Inputs

| Input | Type | Default | Notes |
| --- | --- | --- | --- |
| `service-account` | string | *(required)* | The per-repo job ServiceAccount to run as, e.g. `graph-router-job`. Must already exist -- see `k8s-ci-rbac`'s `jobServiceAccounts`. |
| `namespace` | string | `github-runner` | Namespace the job ServiceAccount lives in. |
| `image` | string | *(required)* | Container image to run. |
| `command` | string | *(required)* | When `shell` is `"true"` (default): a single shell string, wrapped as `sh -c` -- for images with a shell (npm/pytest/Playwright etc). When `shell` is `"false"`: a whitespace-separated arg list passed straight to the image's own `ENTRYPOINT`, no shell involved -- required for shell-less images like kaniko's official executor image. |
| `shell` | string | `"true"` | Set to `"false"` for shell-less images (e.g. kaniko, which has no `/bin/sh` at all). |
| `env` | string | *(empty)* | Newline-separated `KEY=VALUE` pairs to set as container env vars. |
| `secret-volume` | string | *(empty)* | `<secretName>:<mountPath>` -- mounts a Secret as a file inside the container. Needed for kaniko's push credential (`/kaniko/.docker/config.json`): `imagePullSecrets` only affects the kubelet's own image pull, it never puts anything inside the container's own filesystem. The Secret's `.dockerconfigjson` key is remapped to a file named `config.json` at the mount path -- currently the only thing this input is used for. |
| `node-selector` | string | *(empty)* | Comma-separated `key=value` pairs, e.g. `kubernetes.io/arch=arm64`. |
| `tolerations` | string | *(empty)* | Comma-separated `key=value:effect` entries, e.g. `dedicated=pi:NoSchedule` (always uses the `Equal` operator). |
| `checkout-ref` | string | *(empty)* | When set, checks out this ref via a git-clone preamble before running `command` -- for images with no native git-context mechanism of their own (e.g. Playwright's). |
| `active-deadline-seconds` | string | `"900"` | Kubernetes `activeDeadlineSeconds` for the Job -- the backstop that gives up if the pod can never be scheduled at all. |

## Using it from another repo

```yaml
name: Check

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: k8s-amd64
    steps:
      - uses: actions/checkout@<sha> # v4.2.2
      - uses: mattjmorrison-homelab/actions-k8s@<commit-sha>
        with:
          service-account: graph-router-job
          image: gcr.io/kaniko-project/executor@<digest>
          shell: "false" # kaniko's image has no shell -- see command's own doc above
          command: >-
            /kaniko/executor --context=git://github.com/mattjmorrison-homelab/graph-router.git#refs/heads/main
            --dockerfile=Dockerfile --target=release --destination=registry.morrisons.site/graph-router:latest
          secret-volume: zot-pull-secret:/kaniko/.docker
```

**Pin to a commit SHA, not a branch** -- this org requires
`sha_pinning_required` on every `uses:` reference. Get the current SHA
with:

```sh
gh api repos/mattjmorrison-homelab/actions-k8s/commits/main --jq '.sha'
```

No automation keeps these pins current today; update every caller's pin
manually after any change here that should actually take effect.
