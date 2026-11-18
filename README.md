# Azure Admin Toolbox

A personal Azure / Microsoft 365 administration workstation in a container:
PowerShell 7, Azure CLI, Az, curated Graph modules, IaC, Kubernetes and
network troubleshooting tools. Pull a tested image instead of maintaining
all those installations on the Windows host.

This is useful as a local Cloud Shell-like toolbox. Microsoft's
[Azure Cloud Shell](https://learn.microsoft.com/en-us/azure/cloud-shell/overview)
also supplies managed hosting and automatic authentication. This repository
supplies the container; you manage its engine, updates, credentials, networking
and mounted files. A container is not a separate tenant or a complete sandbox
for untrusted scripts.

## Choose the tools you need

| Profile | Includes | Choose it for |
|---|---|---|
| `core` (default) | Azure/M365, IaC, Kubernetes, database and network tools | Normal administration; no standalone .NET SDK or Functions Core Tools |
| `dotnet` | Core plus the .NET 10 SDK | Restore, build, test and publish .NET projects without a host SDK |
| `functions` | Dotnet plus Azure Functions Core Tools v4 | Local .NET Functions development; run Azurite separately if needed |

The SDK was useful for building Functions projects, but it need not be in every
admin shell. PowerShell already carries the runtime it needs; removing the
standalone SDK does not remove PowerShell.

Profiles are **build-time layers**. Pull a different profile image or rebuild
with `TOOLBOX_PROFILE`; `podman run -e TOOLBOX_PROFILE=dotnet ...` cannot add the
SDK to a core image or remove bytes from an existing functions image.

After this revision is merged and a green publishing run completes, `:latest`
and `:core` select core; `:dotnet` and `:functions` select the optional profiles.
Existing local images do not change until pulled/rebuilt. Select `:functions`
to retain the previous SDK/Core Tools bundle.

## Pull and run

From host PowerShell + Podman, choose one image:

```powershell
$image = 'ghcr.io/ljmitch/azadmin:core'
# Alternatives: ghcr.io/ljmitch/azadmin:dotnet or :functions
podman pull $image
if ($LASTEXITCODE -ne 0) { throw 'Image pull failed' }

# Stateless credentials: log in again for this session.
podman run -it --rm -v "${PWD}:/work" -w /work $image
```

For repeated work, credential caches can persist in named volumes:

```powershell
podman run -it --rm `
  -v "${PWD}:/work" -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  -v admin_kube:/root/.kube `
  $image
```

Those volumes contain reusable credentials. Keep separate caches for different
trust contexts, mount only the workspace you need and prefer a read-only
workspace for inspection. Do not mount the host container socket or pass
`--privileged` for ordinary administration. Root inside this toolbox and
write access to a mounted folder can modify that folder's files.

Device-code login, cache cleanup, Functions ports and one-shot commands:
[docs/USAGE.md](docs/USAGE.md). Swap `podman` for `docker` if that is your engine.
The supported image platform is Linux/amd64.

## Build a selected profile locally

```powershell
$profile = 'dotnet' # core, dotnet, functions
$tag = "admin-toolbox:$profile"
podman build --pull=always `
  --build-arg "TOOLBOX_PROFILE=$profile" `
  --build-arg "BUILD_DATE=$(Get-Date -Format o)" `
  -t $tag .
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }

# The verifier lives in the repository, so mount the repo read-only.
podman run --rm -v "${PWD}:/work:ro" -w /work $tag `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1 -ExpectedProfile $profile
if ($LASTEXITCODE -ne 0) { throw 'Toolbox verification failed' }
```

A rebuild plus `Verify-Toolbox.ps1` is required after image/verifier changes.
The checks prove selected tools execute and modules load; an intended Functions
project still needs its own build, trigger/dependency and application tests.
Full build, scan and release process: [docs/BUILD.md](docs/BUILD.md).

## Security and updates

The [18 November profile review](docs/BUILD.md#validated-profile-candidates-18-november-2026)
passed runtime smoke checks but found release-blocking upstream dependencies
and bundled secret samples. The new gates remain blocking; these profiles have
not been published by this review.

CI builds each profile, verifies the loaded artifact and scans that same image
before it can be published. Trivy vulnerability and secret checks fail the
release on their configured policy or scanner errors. JSON reports and an SBOM
are retained as build evidence; a passing scan is time-bound, not proof that an
image has no vulnerabilities. The scanner runs outside the toolbox.

Tools intentionally float at **build time** through package feeds and upstream
releases. Weekly builds refresh them; this does not update a running container
or the image already stored on your laptop. Pull an approved replacement and
start a new container. Record a digest for an exact rollback reference: readable
date/SHA tags alone are not registry-enforced immutability.

Only yq, Helm and source-image selection expose version build arguments today.
Other tools require a reviewed install-layer change to pin. Graph leaves remain
one coordinated Gallery install. See the [inventory](docs/TOOLS.md) and
[build policy](docs/BUILD.md) rather than assuming every tool has a version ARG.

## Repository map

| Path | Purpose |
|---|---|
| [Dockerfile](Dockerfile) | Shared core and optional dotnet/functions stages |
| [scripts/Install-PsModules.ps1](scripts/Install-PsModules.ps1) | Coordinated Az, Graph and Exchange install |
| [scripts/Verify-Toolbox.ps1](scripts/Verify-Toolbox.ps1) | Selected-profile executable/module checks |
| [docs/BUILD.md](docs/BUILD.md) | Builds, scan gates, cache policy and publication |
| [docs/USAGE.md](docs/USAGE.md) | Credentials, mounted projects and daily use |
| [docs/TOOLS.md](docs/TOOLS.md) | Included tools and why they are here |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Recorded failures and their fixes |
| [.github/workflows/build-push.yml](.github/workflows/build-push.yml) | Trusted build, verification, scanning and publication |
| [.github/workflows/validate-pr.yml](.github/workflows/validate-pr.yml) | Unprivileged PR image checks |
| [AGENTS.md](AGENTS.md) | Repository contributor instructions |
| [Makefile](Makefile) | Optional GNU make shortcuts around Podman |
