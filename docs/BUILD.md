# BUILD runbook

How to build, tag, and version-bump the toolbox image.

Day to day you do **not** need this file. Pull and run:

```powershell
podman pull ghcr.io/ljmitch/azadmin:latest
```

Then the `podman run` in [docs/USAGE.md](USAGE.md) / [README.md](../README.md).
The rest of this page is for changing the image itself.

## Standard build

```powershell
podman build -t admin-toolbox:latest .
```

## GitHub repository image variables

The workflow reads both repository variables under Settings -> Secrets and
variables -> Actions -> Variables and passes them as Docker build args:

| Repository variable / build arg | Fallback when the repository variable is blank |
|---|---|
| `BASE_IMAGE` | `ubuntu:24.04` |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0-noble` |

The source-image log step prints the resolved values and whether repository
values were supplied. Buildx `pull: true` refreshes both stages. Merely adding
a GitHub variable does not configure Docker unless the workflow passes it;
both are wired explicitly here.

Local builds use the Dockerfile defaults unless the same build args are
supplied locally. GitHub variables are not downloaded into a local build.
The supported/tested pairing remains Ubuntu 24.04 with the noble .NET 10 SDK;
changing the base requires reviewing SDK/native package/feed compatibility.

## Fresh-rebuild (picks up "latest" floated versions properly)

Cached layers mean a plain rebuild won't re-resolve floating tools - yq, helm,
tflint, checkov, az CLI, Graph/Az modules etc. would serve you last-build's
"latest". Two options:

**Usual** - pull both source images and pass the cache-buster ARG. The final
base defaults to `ubuntu:24.04`; a build stage supplies .NET from
`mcr.microsoft.com/dotnet/sdk:10.0-noble`. `BUILD_DATE` invalidates the Ubuntu
upgrade/tool layers, but cannot update the SDK bytes in a cached source image.
Use `--pull=always` for Podman (`--pull` for Docker) as well.

```powershell
podman build --pull=always --build-arg "BUILD_DATE=$(Get-Date -Format o)" -t admin-toolbox:latest .
```

**Nuclear** - pull source images and ignore every build layer. Slowest:

```powershell
podman build --pull=always --no-cache -t admin-toolbox:latest .
```

## Functions branch acceptance

Use a separate local candidate tag while changing the image:

```powershell
podman build --pull=always --build-arg "BUILD_DATE=$(Get-Date -Format o)" -t admin-toolbox:functions .
podman run --rm -v ${PWD}:/work -w /work admin-toolbox:functions pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1
podman image inspect admin-toolbox:functions --format '{{.Size}}'
```

Compare size/history with the previous image if retained. A rebuild plus
`Verify-Toolbox.ps1` is required before promoting a tag. Also build/run the
intended .NET project and test its HTTP/queue path separately; the version
smoke test is not an application integration test. This branch has not been
published merely because these source changes exist.

For Docker Desktop, the build equivalent is `docker build --pull` with the
same build arg/tag; the run/inspect commands use `docker` in place of `podman`.

Local check on 2026-11-04: Docker built `admin-toolbox:functions-review` from
this branch and the complete `Verify-Toolbox.ps1` passed. The image reported
Ubuntu 24.04.5, .NET SDK 10.0.403, Core Tools 4.16.0 and PowerShell 7.6.9.
A temporary .NET 10 HTTP function compiled/started inside it and returned
HTTP 200 using a separate local Azurite container. No Azure login, deployment,
Service Bus message operation or registry push was performed. The disposable
test containers/network were removed; the local review image was retained.

The built image reported 7,341,607,841 bytes (about 7.3 GB unpacked). Its
`/usr/share/dotnet` directory occupied about 624 MiB and Core Tools about
1.3 GiB. This is not a measured before/after delta against an older image:
other floating tools also refreshed. Compressed registry downloads and shared
layer storage differ from the unpacked total. The extra capability is
intentional for this personal toolbox; Azurite/Node/npm were not added.

## Pinning instead of floating

Yq/Helm expose version build args. `DOTNET_SDK_IMAGE` can pin the .NET SDK
source to a compatible noble .NET 10 image tag/digest. Other tool policies
are listed below; they do not all expose version args:

```powershell
# Specific release of yq or helm:
podman build -t admin-toolbox:latest --build-arg YQ_VERSION=v4.48.2 .
podman build -t admin-toolbox:latest --build-arg HELM_VERSION=v3.16.1 .
```

Pins applied this way are one-off builds. To make a pin the *new default*,
change the ARG in the Dockerfile header so future default builds carry it.

Az, Graph, and ExchangeOnlineManagement have no version ARG: they take
gallery latest at build time. Re-resolve with `BUILD_DATE` (or `--no-cache`).

## Tag after verification only

```powershell
$today = Get-Date -Format 'yyyy-MM-dd'
podman tag admin-toolbox:latest "admin-toolbox:$today"
```

Rollback later = `podman tag admin-toolbox:$today admin-toolbox:latest` from
an older dated tag.

## Verify after every rebuild

The verify script is NOT in the image - mount the repo in first:

```powershell
podman run --rm -v ${PWD}:/work -w /work admin-toolbox:latest pwsh -NoProfile -File .\scripts\Verify-Toolbox.ps1
```

All checks must say `VERIFY PASSED` before you tag the image.

## Current pin/float policy (Nov 2026)

| Component | Mode | Control |
|---|---|---|
| Final base | `BASE_IMAGE`, default Ubuntu 24.04 | GitHub repository variable or local `--build-arg BASE_IMAGE=...`; other bases need compatibility review |
| .NET SDK source | rolling `10.0-noble` image by default | refresh with `--pull=always`; `DOTNET_SDK_IMAGE` can select a compatible pinned tag/digest |
| Functions Core Tools | GA v4 from PMC noble apt | refresh install layer with `BUILD_DATE` or `--no-cache` |
| Ubuntu base packages (`libc6`, `base-files`, ...) | `apt-get upgrade` on the first apt layer | cache-bust (`BUILD_DATE`) or `--no-cache`; a plain rebuild reuses the old upgrade |
| yq | floats to GitHub latest (default) | `--build-arg YQ_VERSION=vX.Y.Z` to pin |
| helm | floats to GitHub latest (default) | `--build-arg HELM_VERSION=vX.Y.Z` to pin |
| PowerShell (pwsh) | floats via PMC apt (noble feed) | cache-bust + PMC handles it; .deb fallback below if the feed lags |
| Azure CLI | floats via `repos/azure-cli/` apt | cache-bust to re-fetch |
| Az PowerShell module | floats to gallery latest | cache-bust (`BUILD_DATE`) to re-fetch |
| Microsoft.Graph leaves | floats, ALL leaves in one `Install-Module` | same - they resolve together; do not pin leaves independently |
| ExchangeOnlineManagement | floats to gallery latest | n/a |
| Terraform | floats via HashiCorp apt (noble-compatible, codename-resolved) | re-pin via `apt-get install -y "terraform=${TF_VERSION}-1"` if needed |
| tflint | floats to GitHub latest + SHA256 checksum verify | swap `releases/latest/download/` for `releases/download/vX.Y.Z/` in Dockerfile |
| checkov | floats via pip | n/a |
| kubectl / kubelogin | floats via `az aks install-cli` | n/a |
| azd | floats via install script | n/a |
| azcopy | floats via aka.ms alias | n/a |
| psql client | floats via PGDG (18.x at time of writing, not Ubuntu's aged 16) | pin via `apt-get install -y postgresql-client-16` if needed |

To demote a floating tool to pinned: in the RUN layer, replace the
release resolution block with a version-embedded URL, and update the ARG.

## PMC feed notes (war stories)

1. **`azure-cli` is NEVER in the general PMC feed.** It ships from
   `https://packages.microsoft.com/repos/azure-cli/` (suite matches the
   detected Ubuntu codename). The general PMC feed at
   `packages.microsoft.com/config/ubuntu/<ver>/` provides PowerShell and
   other MS packages only.
2. **New Ubuntu codename lag happens.** As of 14-Sep-2026, 24.04 (noble)
   is the base of choice because the PMC noble feed carries `powershell`
   reliably; experimental 26.04 builds showed base-image viability but we
   want PMC stability before committing. Re-check monthly.
3. **Base-version-agnostic repos in play.** Repo URIs resolve the Ubuntu
   codename via `grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release` -
   flipping `FROM ubuntu:26.04` later won't require per-line repo edits,
   just PMC feed availability.

### Fallback: PowerShell via universal .deb

If the PMC block ever errors with `Unable to locate package powershell`,
comment it out and use the GitHub universal package:

```dockerfile
ARG PWSH_VERSION=7.6.6
RUN wget -q https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell_${PWSH_VERSION}-1.deb_amd64.deb -O /tmp/pwsh.deb \
 && apt-get update && apt-get install -y /tmp/pwsh.deb && rm /tmp/pwsh.deb
```

(The azure-cli block is independent - leave it alone.)

Note: the current base (noble) works with the PMC apt path; the `.deb`
fallback is a contingency plan.

## Pushing to GHCR (CI)

GitHub Actions (`.github/workflows/build-push.yml`) builds with **Docker
Buildx** on `ubuntu-latest`, runs `scripts/Verify-Toolbox.ps1`, then pushes
to `ghcr.io/<owner>/<repo>`. Docker is the CI path; Podman stays for local
builds. GitHub-hosted Ubuntu runners include both (see
[runner-images](https://github.com/actions/runner-images)) but Podman on
those images has had version/registry churn; the official `docker/*` actions
target GHCR.

Triggers:

- Weekly Monday 04:00 UTC - passes `BUILD_DATE`; Buildx `pull: true` refreshes
  Ubuntu and the SDK source, then floating apt/tools resolve again
- Push to `main` that touches the Dockerfile, scripts, profile, or the
  workflow itself - pulls source images and uses layer cache, no `BUILD_DATE`
- Actions tab -> Run workflow - optional cache-bust checkbox (on by default)

Tags pushed after verify: `latest`, `YYYY-MM-DD`, `sha-<shortsha>`.

```powershell
podman pull ghcr.io/ljmitch/azadmin:latest
podman pull ghcr.io/ljmitch/azadmin:2026-09-16   # pin a day's build
```

Run it (full persist) from any folder:

```powershell
podman run -it --rm `
  -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  -v admin_graph:/root/.local/share/IdentityCache `
  -v admin_kube:/root/.kube `
  ghcr.io/ljmitch/azadmin:latest
```

First successful publish creates a **private** GHCR package
([docs](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#pushing-container-images)).
For anonymous pull from this public repo: GitHub -> Packages -> the image ->
Package settings -> Change visibility -> Public.

No extra PAT. The workflow uses `GITHUB_TOKEN` with `packages: write`. The
Dockerfile `org.opencontainers.image.source` label links the package to this
repo so that token is allowed to push.

## Pushing to a registry (manual, optional)

```powershell
podman tag admin-toolbox:latest <your-acr>.azurecr.io/admin-toolbox:latest
az acr login --name <your-acr>
podman push <your-acr>.azurecr.io/admin-toolbox:latest
```

Only do this if the image content is genuinely shareable - it contains no
secrets, but your org's policy is the final word. For a public repo the
correct target is GHCR (`ghcr.io/ljmitch/azadmin`), which CI already publishes.

## Dependency updates and PR validation

`.github/dependabot.yml` checks GitHub Actions every Monday at 09:30 UK time.
Minor/patch updates are grouped; major updates get separate PRs for review.
The limit is three open version-update PRs. Dependabot starts using this
configuration after it reaches the default branch.

This differs from the website configuration: there are no npm dependencies
here. Docker update PRs are intentionally omitted. Ubuntu 24.04 and .NET 10
noble are deliberate compatibility choices, their tags refresh on rebuild,
and repository variables can override the Dockerfile defaults. Dependabot
does not update those repository variables or the tools installed from
apt, PowerShell Gallery and floating download URLs.

`Validate toolbox PR / build-and-verify` builds and runs the complete toolbox
verification for PRs touching image inputs, Dependabot or workflows. It uses
`pull_request`, read-only repository permissions and no registry login/push.
It reads the existing build cache but exports no PR cache or build-record
artifact. New commits cancel the previous check for that PR. Documentation-only
PRs do not run the image build. The check validates installed tools, not every
Azure operation or application integration.

Dependabot opens PRs; this configuration does not enable automatic merging.
Review the diff and green check, then merge manually. Opening a PR only builds
a local candidate on the runner. Merging an action update to the publishing
workflow triggers the existing main-branch build and publish, in addition to
the weekly scheduled refresh. A change only to Dependabot or the PR-validation
workflow does not match the publishing workflow's path filter.

This repository is public. Standard GitHub-hosted Ubuntu runner compute is
free for public repositories; no paid scanner, larger runner or new artifact
storage is introduced. Recheck billing if the repository becomes private.
See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

Optional GitHub setting: require the PR build-and-verify check before merging.
Because this workflow has path filters, do not require it unconditionally for
all PRs: documentation-only PRs would wait for a check that never starts. Remove the filters before requiring this check for every PR. Repository rules and auto-merge settings are not changed
by these files.
