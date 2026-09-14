# TOOLS inventory

Everything installed in the image, how it got there, and how it's versioned.
Cross-check with `docs/BUILD.md` - that file is the source of truth for the
pin/float policy (last baselined Sep 2026).

## System-level (apt, Ubuntu noble archive)

| Tool | Why |
|---|---|
| `git` | Repo work inside the container itself |
| `curl`, `wget` | Generic fetch plumbing |
| `unzip`, `zip` | Archive handling |
| `less` | Paging long output inside the shell |
| `ca-certificates` | TLS trust store - every tool leans on it |
| `jq` | JSON selectors without writing a script |
| `rsync` | Sync mirrors between host-mounted dirs and volumes |
| `python3` + `pip` | Required for `checkov` |
| `dnsutils` | `dig`, `nslookup`, `host` - service debugging |
| `iputils-ping` | basic ICMP liveness checks |
| `netcat-openbsd` | `nc` port probes for "is that even listening?" |
| `traceroute` | hop-level network diagnosis |
| `lsb-release` | Needed for `$(lsb_release -cs)` codename resolution |
| `openssh-client` | `ssh`, `scp`, `sftp` - both direct and via Bastion |

The first apt `RUN` does `apt-get upgrade` before `install`, so packages that
already shipped in `ubuntu:24.04` (`libc6`, `base-files`, ...) take
noble-updates / noble-security at build time. `apt-get install` alone would
leave them frozen. Re-run that layer with `BUILD_DATE` or `--no-cache`.

(psql does NOT come from Ubuntu's archive - see PGDG row below.)

## Package repos added beyond Ubuntu's

| Repo | Supplies | Notes |
|---|---|---|
| `packages.microsoft.com/config/ubuntu/$VERSION_ID/` (PMC) | PowerShell (pwsh) | noble feed is the working base; resolute feed lags |
| `packages.microsoft.com/repos/azure-cli/` (codename-resolved) | Azure CLI + Bicep | separate MS feed - NEVER in the main PMC repo |
| `apt.releases.hashicorp.com` (codename-resolved) | Terraform | no hardcoded "noble" string; survives base bumps |
| `cli.github.com/packages` | GitHub CLI (`gh`) | added because GitHub repo work is in-scope |
| `apt.postgresql.org` (PGDG) | `postgresql-client` (latest 18.x line) | Ubuntu's archive would give 16.x - several versions behind Azure DB for PostgreSQL targets |

## CLIs (install method → version mode)

| Tool | How | Versioned | Why it's here |
|---|---|---|---|
| `pwsh` | PMC apt | floats with PMC on noble | The shell the image drops into |
| `gh` | github-cli apt repo | floats | GitHub repo/PR/Actions work inside the container |
| `az` CLI | azure-cli apt repo | floats | ARM/Bicep deployment + subscription plumbing; also installs Bicep via `az bicep install` |
| `bicep` | via `az bicep install` | floats | Bicep templates without a separate download |
| `azd` | `aka.ms/install-azd.sh` | floats | Template-first Azure app flows (`azd up`) |
| `yq` | GitHub release binary | floats to latest by default; `--build-arg YQ_VERSION=vX.Y.Z` pins | YAML grep/edit; jq's YAML sibling |
| `terraform` | HashiCorp apt | floats; pin via `apt-get install -y "terraform=${TF_VERSION}-1"` if re-pinning | IaC day job |
| `tflint` | GitHub release zip + sha256sum verify | floats to latest; pin by editing URL to `releases/download/vX.Y.Z/` | Terraform static analysis |
| `checkov` | `pip3 --break-system-packages` | floats | IaC security/policy scan, loads hundreds of resource types |
| `kubectl` | `az aks install-cli` | floats (stable at build time) | AKS operations |
| `kubelogin` | `az aks install-cli` | floats | Entra-auth'd AKS login (mandatory on most clusters now) |
| `helm` | upstream tarball, version resolved from GitHub | floats to latest by default; `--build-arg HELM_VERSION=vX.Y.Z` pins | K8s package manager |
| `azcopy` | `aka.ms/downloadazcopy-v10-linux` tarball | floats | Large blob/file copy between storage accounts + local |
| `psql` | PGDG apt (postgres repo) | floats with PGDG `postgresql-client` metapackage | Azure Database for PostgreSQL connections |

## az CLI extensions (installed via `az extension add`)

| Extension | Why |
|---|---|
| `azure-devops` | `az pipelines`/`az repos`/`az boards` surfaces - Azure DevOps admin from CLI |
| `aks-preview` | Latest AKS features, runs alongside the stable CLI |
| `ssh` | `az network bastion ssh` and `az ssh vm` without external ssh config plumbing |

## PowerShell modules (installed via `pwsh` + PSGallery)

| Module | Versioned | Why |
|---|---|---|
| `Az` | floats (gallery latest at build) | Azure resource cmdlet surface |
| `Microsoft.Graph.Authentication` | floats with the other leaves | Base dependency every Graph call resolves through |
| `Microsoft.Graph.Users` | floats (same install) | Get-MgUser, licenses, guests |
| `Microsoft.Graph.Users.Actions` | floats (same install) | Password resets, session revocation |
| `Microsoft.Graph.Groups` | floats (same install) | Get-MgGroup, members, M365 group mgmt |
| `Microsoft.Graph.Applications` | floats (same install) | Get-MgApplication / ServicePrincipal flows |
| `Microsoft.Graph.Identity.SignIns` | floats (same install) | Risky users / CA policies / conn checks |
| `Microsoft.Graph.Identity.DirectoryManagement` | floats (same install) | Org, domain, subscription metadata |
| `Microsoft.Graph.Sites` | floats (same install) | SharePoint/OneDrive site ops |
| `Microsoft.Graph.Files` | floats (same install) | Get-MgDrive + OneDrive across users |
| `Microsoft.Graph.Mail` | floats (same install) | Read/report on user mailboxes |
| `ExchangeOnlineManagement` | floats | EXO bits Graph doesn't cover |

**Graph rule - install all leaves in one `Install-Module`.** All 10 Microsoft.Graph
modules must resolve together. Mixing `-RequiredVersion` across leaves is how
the TypeLoadException scar happened (see TROUBLESHOOTING.md). There is no
per-leaf pin ARG; bump everything by rebuilding with `BUILD_DATE`.

## ARG policy summary

| ARG | Default | Effect |
|---|---|---|
| `YQ_VERSION` | `latest` | resolves from `api.github.com/repos/mikefarah/yq/releases/latest` at build; pin with explicit `vX.Y.Z` to freeze |
| `HELM_VERSION` | `latest` | same pattern - `helm/helm` repo |
| `TF_VERSION` | informational only | Terraform floats via apt regardless; ARG documents intent |
| `PWSH_VERSION` | informational only | PowerShell floats via PMC noble feed; use .deb fallback to pin |
| `BUILD_DATE` | `unknown` | cache-buster - passing a timestamp forces re-resolution of all floaters |

To **demote a floated tool to pinned**: edit its RUN layer's release-resolution
block, replace with a version-embedded URL / explicit apt version, and bump the
matching ARG default. Flip it back by reverting the RUN layer and letting the
ARG read `latest`.

To **promote a new tool that doesn't fit either bucket**, see the last section.

## Adding a tool

1. Decide install method - apt feed, GitHub release zip/tarball, script pipe, or PSGallery.
2. Pick float-vs-pin policy deliberately. If float-by-default, reuse the yq/helm
   resolution-block pattern (`ARG X_VERSION=latest` + conditional resolution in RUN).
3. Add to the matching `RUN` layer in the Dockerfile (per-responsibility grouping).
   PowerShell modules go in `scripts/Install-PsModules.ps1`, not inline in the Dockerfile.
4. Extend `scripts/Verify-Toolbox.ps1` with a check that exercises both presence
   and a basic invocation (`--version` or `$PSCmdlet` import).
5. Update this file AND `docs/BUILD.md`'s policy table.
6. **Scar-driven**: if the install failed in a memorable way, append a scar entry in
   `docs/TROUBLESHOOTING.md`.

Cache note: choose which RUN layer a new tool nests into deliberately - share
with the tool it logically accompanies so cache invalidation steps are obvious
and layering stays lean.
