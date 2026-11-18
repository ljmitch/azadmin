# TOOLS inventory

Tools installed by each profile, how they get there and their update policy.
Cross-check with [BUILD.md](BUILD.md) and the Dockerfile when changing the list.

## Profiles

| Profile | Installed tool set |
|---|---|
| `core` | All administration tools below except the standalone .NET SDK and Functions Core Tools |
| `dotnet` | Core plus the .NET 10 SDK |
| `functions` | Dotnet plus Azure Functions Core Tools v4 |

Core is the default. `TOOLBOX_PROFILE` selects build-time stages, not runtime
package installation. Select another published profile or rebuild to change
the optional tool set. PowerShell's own bundled runtime remains in core.
The supported image platform is Linux/amd64; hardcoded upstream downloads must
be adapted and tested before claiming native arm64 support.

## System-level (apt, Ubuntu noble archive)

The first apt `RUN` does `apt-get upgrade` before `install`, so packages that
already shipped in the final `ubuntu:24.04` base (`libc6`, `base-files`, ...) take
noble-updates / noble-security at build time. `apt-get install` alone would
leave them frozen. Re-run that layer with `BUILD_DATE` or `--no-cache`.

(psql does NOT come from Ubuntu's archive - see PGDG row below.)

### Fetch, files, and shell plumbing

| Tool | Why |
|---|---|
| `git` | Repo work inside the container itself |
| `curl`, `wget` | Generic fetch plumbing |
| `unzip`, `zip` | Archive handling |
| `less` | Paging long output inside the shell |
| `ca-certificates` | TLS trust store - every tool leans on it |
| `jq` | JSON selectors without writing a script |
| `rsync` | Sync mirrors between host-mounted dirs and volumes |
| `python3`, `python3-venv` + `pip` | Checkov runs in its own `/opt/checkov` virtual environment |
| `procps` | `ps`, `top`, `free`, `pgrep` - process view without hoping the base image shipped them |
| `lsb-release` | Needed for `$(lsb_release -cs)` codename resolution |

### Network (core)

| Tool | Why |
|---|---|
| `dnsutils` | `dig`, `nslookup`, `host` - service debugging |
| `iputils-ping` | basic ICMP liveness checks |
| `netcat-openbsd` | `nc` port probes for "is that even listening?" |
| `traceroute` | hop-level network diagnosis |
| `openssh-client` | `ssh`, `scp`, `sftp` - both direct and via Bastion |

## Network extras (Ubuntu noble apt)

Extra network CLIs from the Ubuntu 24.04 archive (`apt-get`,
`--no-install-recommends`). Same first apt layer as the core set, listed
here so they stay below the main toolset.

### Routing and sockets

| Tool | Why |
|---|---|
| `iproute2` | `ip addr` / `ip route` / `ip neigh` / `ss` - what the box thinks its network is |

### Path and reachability

| Tool | Why |
|---|---|
| `mtr-tiny` | traceroute + ping in one, no X11 (`mtr`) |
| `tcptraceroute` | hop path over TCP when ICMP is blocked (common in Azure) |
| `iputils-tracepath` | `tracepath` - MTU discovery along the path |
| `fping` | ICMP many hosts at once (subnet of VMs) |
| `hping3` | TCP "ping" / crafted probes when ICMP is filtered |

### Throughput and capture

| Tool | Why |
|---|---|
| `iperf3` | TCP/UDP throughput (VNet, VPN, ExpressRoute) |
| `tcpdump` | packet capture in the selected network namespace; specific capabilities may be needed, not automatic full privilege |

### Connectivity, TLS, and addressing

| Tool | Why |
|---|---|
| `socat` | relay, TLS wrap, one-off port forward |
| `openssl` | `openssl s_client` for App Gateway / Front Door / Key Vault certs |
| `nmap` | port/range check through NSGs (`nping` is a suggest, not pulled) |
| `ipcalc` | VNet CIDR / mask math |
| `whois` | IP and domain registration lookup |

## Package repos added beyond Ubuntu's

| Repo | Supplies | Notes |
|---|---|---|
| `packages.microsoft.com/config/ubuntu/$VERSION_ID/` (PMC) | PowerShell; Core Tools only in functions | noble is the selected compatible base; verify newer feeds before changing it |
| `packages.microsoft.com/repos/azure-cli/` (codename-resolved) | Azure CLI + Bicep | separate MS feed - NEVER in the main PMC repo |
| `apt.releases.hashicorp.com` (codename-resolved) | Terraform | derived URLs still need upstream support for a proposed base |
| `cli.github.com/packages` | GitHub CLI (`gh`) | added because GitHub repo work is in-scope |
| `apt.postgresql.org` (PGDG) | Current `postgresql-client` metapackage | Verify the selected client/server combination; use its recorded build version rather than assuming a permanent latest major |

## CLIs (install method → version mode)

| Tool | How | Versioned | Why it's here |
|---|---|---|---|
| `pwsh` | PMC apt | `PWSH_VERSION` | The shell the image drops into |
| `dotnet` SDK (dotnet/functions) | `/usr/share/dotnet` copied from `mcr.microsoft.com/dotnet/sdk:10.0-noble` | floats within .NET 10; `DOTNET_SDK_IMAGE` can pin a compatible image/digest | Restore, build, test and publish .NET projects |
| `func` (functions only) | PMC apt, `azure-functions-core-tools-4` | `FUNCTIONS_VERSION` | Scaffold/run Functions locally and publish through an authorised workflow |
| `gh` | github-cli apt repo | `GH_VERSION` | GitHub repo/PR/Actions work inside the container |
| `az` CLI | azure-cli apt repo | `AZURE_CLI_VERSION` | ARM/Bicep deployment and subscription management |
| `bicep` | via `az bicep install` | `BICEP_VERSION` | Bicep template tooling |
| `azd` | `aka.ms/install-azd.sh` | `AZD_VERSION` | Template-first Azure app flows (`azd up`) |
| `yq` | GitHub release binary | `YQ_VERSION` | YAML grep/edit |
| `terraform` | HashiCorp apt | `TF_VERSION` | Infrastructure as code |
| `tflint` | GitHub release zip with SHA-256 verification | `TFLINT_VERSION` | Terraform static analysis |
| `checkov` | pip in `/opt/checkov` venv, launcher on PATH | `CHECKOV_VERSION` | IaC security and policy scanning |
| `kubectl` | `az aks install-cli` | `KUBECTL_VERSION` | AKS operations |
| `kubelogin` | `az aks install-cli` | `KUBELOGIN_VERSION` | Microsoft Entra authentication for AKS |
| `helm` | Upstream tarball with SHA-256 verification | `HELM_VERSION` | Kubernetes package manager |
| `azcopy` | Microsoft Linux tarball | `AZCOPY_VERSION` | File copy between storage accounts and local filesystems |
| `psql` | PGDG apt (postgres repo) | floats with PGDG `postgresql-client` metapackage | Azure Database for PostgreSQL connections |

## Optional SDK/Functions layers and image size

All profiles inherit `ubuntu:24.04` through `BASE_IMAGE`. The optional dotnet
stage supplies the maintained .NET 10 SDK, reference packs and shared runtimes. Only
`/usr/share/dotnet` is copied, so the source SDK image's bundled PowerShell
is not installed a second time; this toolbox keeps its existing PMC pwsh.
The dotnet stage explicitly supplies its native dependencies. Functions builds
on that stage and adds Core Tools; core contains neither standalone developer tool.

The SDK and Core Tools add real size. Keep them only in profiles where their
development capability is needed.
There is no new Node/npm installation, emulator process or development workload
bundle. Run Azurite separately when required. The historical 2026-11-04 full candidate
was about 7.3 GB unpacked; SDK/Core Tools directories together occupied
roughly 2 GB. See BUILD.md for the actual
verification and HTTP smoke-test evidence. This predates the profile split;
there is no measured new profile delta or compressed-download claim.

`Get-ToolboxVersions` reports the selected profile and optional tool availability.
Verification checks that a 10.0 SDK executes in dotnet/functions, Core Tools v4
executes only in functions, and those tools are absent from profiles excluding them. It does not
prove an application's dependencies, Azure identity or queue consumption work.

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

## Version controls

CLI selectors in the inventory default to `latest` in their respective channels.
The build guide gives the exact forms accepted by each installer and shows how
to pass the same overrides to Make, Podman or CI.
[Choose tool versions](BUILD.md#choose-tool-versions)

Betterleaks and Trivy run on the CI worker. Betterleaks defaults to the latest
stable release and accepts an exact v1 tag. Trivy uses the checked-in version
and checksum with a current vulnerability database.
[Scan before publishing](BUILD.md#4-scan-before-publishing)

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
