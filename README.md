# Azure Admin Toolbox

Reusable, rebuild-when-you-need-it container image with the tools used for
day-to-day Azure / Microsoft 365 admin work:

| Layer | Contents |
|---|---|
| Base | Ubuntu 24.04 LTS (noble) |
| Shells | PowerShell 7.x (pwsh), bash |
| Azure | az CLI (+ Bicep), Az PowerShell, azd, gh CLI |
| Azure extensions | `azure-devops`, `aks-preview`, `ssh` |
| M365 / Graph | Curated Microsoft.Graph leaf set (10 modules, gallery latest at build), ExchangeOnlineManagement |
| Kubernetes | kubectl + kubelogin (via `az aks install-cli`), helm (resolved from GitHub releases) |
| IaC | Terraform (HashiCorp apt), tflint (SHA-verified latest), checkov |
| Storage | azcopy |
| Web/data | curl, wget, jq, yq (floats by default), git, psql client (latest via PGDG, not Ubuntu's stale copy) |
| Network | dnsutils, iputils-ping, netcat-openbsd, traceroute |

## Version philosophy

- Everything floats to **latest by default**, resolved at **build time**
  via GitHub releases (yq, helm) or distribution feeds (apt, PSGallery,
  MS PMC).
- Pin anything explicitly with `--build-arg`, e.g.:
  `podman build -t admin-toolbox:latest --build-arg YQ_VERSION=v4.48.2 .`
- Force re-resolution of floaters by passing a build date:
  `podman build --build-arg BUILD_DATE=$(Get-Date -Format yyyyMMddHHmm) -t admin-toolbox:latest .`
- Graph leaves install together in one `Install-Module` (no per-leaf version).
  Mixing versions across leaves recreates the TypeLoadException scar
  (see docs/TROUBLESHOOTING.md).

## Quickstart (podman)

```powershell
# Build (floats resolve at build time)
podman build -t admin-toolbox:latest .

# Pin examples (yq / helm only; modules float to gallery latest)
podman build -t admin-toolbox:latest --build-arg YQ_VERSION=v4.48.2 .

# Smoke test - MUST bind-mount the repo so the script is visible
podman run --rm `
  -v ${PWD}:/work -w /work `
  admin-toolbox:latest `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1

# Use it (full credential persistence - see docs/USAGE.md for the options table)
podman run -it --rm `
  -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  -v admin_graph:/root/.local/share/IdentityCache `
  -v admin_kube:/root/.kube `
  admin-toolbox:latest
```

(`docker` runs identically if Podman isn't your constraint.)

## Repo map

| Path | Purpose |
|---|---|
| `Dockerfile` | Entire image definition. Tools float by default; pin via `--build-arg`. |
| `scripts/Install-PsModules.ps1` | Build-time Az + Graph + ExchangeOnlineManagement install (gallery latest) |
| `scripts/Verify-Toolbox.ps1` | Smoke test - proves every binary + module loads and reports versions |
| `AGENTS.md` | Notes for coding agents - pointers into `docs/`, not a second runbook |
| `docs/BUILD.md` | Build, tag, version-bump runbook. Includes PMC-lag fallback |
| `docs/USAGE.md` | Login persistence options (full/stateless/partial), token cache hygiene, passkey auth, workflows |
| `docs/TOOLS.md` | Inventory of every tool + why it's here |
| `docs/TROUBLESHOOTING.md` | Known failures (scars) that shaped the image |
| `config/powershell/…` | Optional pwsh profile baked into the image |

## Updating tools

1. Edit the relevant `ARG` at the top of the `Dockerfile` (default is
   `latest`; set a pinned value to force a specific version)
2. `podman build -t admin-toolbox:latest --build-arg BUILD_DATE=$(Get-Date -Format yyyyMMddHHmm) .`
   (the BUILD_DATE busts cache through the floating layers so they
   actually re-resolve)
3. Tag with a date (`admin-toolbox:2026-09-14`) so rollback is `docker`-trivial
4. Run `Verify-Toolbox.ps1` before pinning the tag

See `docs/BUILD.md` for the full runbook and `docs/USAGE.md` for the login
persistence matrix (full / stateless / partial).

## Notes

- **Ubuntu 24.04 noble base**: PowerShell/apt/tflint/checkov shortcuts.
  Base-version-agnostic repo URLs mean future base bumps won't need Dockerfile
  edits - the codename-resolution idiom (`grep -oP '(?<=UBUNTU_CODENAME=).*'
  /etc/os-release`) handles whichever Ubuntu we land on.
- **psql from PGDG, not Ubuntu**: Ubuntu noble ships postgresql-client-16;
  the toolbox uses the PGDG bootstrap (`/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh`)
  so we get the current upstream (18.x at time of writing). Azure Database
  for PostgreSQL 17 targets work properly from inside.
- **Image-layer caching discipline**: cheap/high-churn layers come early;
  expensive downloads come late. Rearranging is fine as long as the
  `BUILD_DATE` cache-buster sits *above* the expensive stuff it needs to re-run.
