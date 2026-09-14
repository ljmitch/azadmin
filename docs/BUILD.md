# BUILD runbook

How to build, tag, and version-bump the toolbox image.

## Standard build

```powershell
podman build -t admin-toolbox:latest .
```

## Fresh-rebuild (picks up "latest" floated versions properly)

Cached layers mean a plain rebuild won't re-resolve floating tools - yq, helm,
tflint, checkov, az CLI, Graph/Az modules etc. would serve you last-build's
"latest". Two options:

**Usual** - cache-buster ARG. Invalidates every layer after `ARG BUILD_DATE`
(Ubuntu `apt-get upgrade` + all tools). `FROM ubuntu:24.04` stays cached;
the next RUN still `apt-get update && upgrade`, so libc/base-files security
updates land without pulling a newer base.

```powershell
podman build --build-arg "BUILD_DATE=$(Get-Date -Format o)" -t admin-toolbox:latest .
```

**Nuclear** - ignore every layer. Also `podman pull ubuntu:24.04` first if you
want a newer base tag, not just upgraded packages on top of the old one.
Slowest:

```powershell
podman pull ubuntu:24.04
podman build --no-cache -t admin-toolbox:latest .
```

## Pinning instead of floating

Every tool that floats by default accepts a `--build-arg` override:

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

## Current pin/float policy (Sep 2026)

| Component | Mode | Control |
|---|---|---|
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

## Pushing to a registry (optional)

```powershell
podman tag admin-toolbox:latest <your-acr>.azurecr.io/admin-toolbox:latest
az acr login --name <your-acr>
podman push <your-acr>.azurecr.io/admin-toolbox:latest
```

Only do this if the image content is genuinely shareable - it contains no
secrets, but your org's policy is the final word. For a public repo the
correct target is usually GitHub Packages (`ghcr.io/<your-user>/admin-toolbox`
after `gh auth login`).
