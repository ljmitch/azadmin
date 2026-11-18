# Agent notes

This file is for coding agents. Human docs live in `docs/` - read those
instead of copying policy into chat or into this file.

## What this repo is

A personal, rebuild-when-you-need-it Azure / Microsoft 365 admin toolbox
image: Ubuntu 24.04 (noble), PowerShell 7, Azure CLI, Az + curated
Microsoft.Graph leaves, plus IaC and Kubernetes CLIs. It is a lab/toolbox
image, not a product.

`TOOLBOX_PROFILE=core` is the default. Optional `dotnet` and `functions`
profiles add the .NET SDK and then Core Tools at build time. Keep the verifier,
profile helpers, inventory and CI gates aligned when changing these layers.

Do not add tenant names, subscription IDs, ACR hostnames, or other
environment-specific facts. Keep examples generic (`<org>`, `<acr>`).

## Read first

| Need | File |
|---|---|
| What is installed, and why | [docs/TOOLS.md](docs/TOOLS.md) |
| Build, pin/float, cache-bust vs `--no-cache` | [docs/BUILD.md](docs/BUILD.md) |
| How to run it (volumes, login, one-shots) | [docs/USAGE.md](docs/USAGE.md) |
| Known failures (scars) | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Image definition | [Dockerfile](Dockerfile) |
| CI (GHCR) | [.github/workflows/build-push.yml](.github/workflows/build-push.yml) |
| Human overview | [README.md](README.md) |

## Hard rules

- Do not `terraform apply`, `az deployment`, push, open a PR, rotate
  secrets, or change a live cloud resource unless the user explicitly asks.
- Do not invent resource IDs, subscription facts, or "I applied it".
- Tools float in their configured channels by default at **build time**.
  Use documented version build arguments for explicit overrides. Do not re-introduce
  `GRAPH_MODULE_VERSION` / `AZ_MODULE_VERSION`. All Graph leaves install
  together in one `Install-Module` ([scripts/Install-PsModules.ps1](scripts/Install-PsModules.ps1)).
- Never put `#` comments inside a backslash-continued
  `pwsh -Command "..."` RUN. That joins onto one line and the first `#`
  comments out the rest of the install. See TROUBLESHOOTING scar 18.
- Dockerfile `RUN` uses `/bin/sh` (dash on Ubuntu). Use `.` not `source`.
- After changing the image or verify script, say that a rebuild +
  [scripts/Verify-Toolbox.ps1](scripts/Verify-Toolbox.ps1) is required.
  Do not claim the tagged image is good without that.
- Keep docs in sync with the Dockerfile. Add or remove a tool: update
  TOOLS.md, Verify-Toolbox.ps1, and BUILD.md if the pin/float policy changed.
- If a build or runtime failure is memorable, append a scar to
  TROUBLESHOOTING.md in the same session. Do not leave it only in chat.
- Prose: never use an em dash (U+2014). Use a hyphen with spaces (` - `)
  or a colon.
- No filler: "as an AI", "it's important to note", "delve", "robust",
  "weaponise".
- Never mention Cursor, AI, or agents in commits, PRs, code comments, or
  human-facing docs. This file is the exception.

## Comments in code

Comment **why**, not **what**. Dockerfile layer headers should name the
feed and the gotcha (PMC vs azure-cli, PEP-668, Graph comment-join scar).
PowerShell scripts get a short `.SYNOPSIS` / `.DESCRIPTION`. Do not narrate
obvious `apt-get install` lines.

## Build and verify

Host is Windows PowerShell + Podman. Day to day, pull GHCR rather than build:

```powershell
podman pull ghcr.io/ljmitch/azadmin:latest
```

Local rebuild runbook: [docs/BUILD.md](docs/BUILD.md).

```powershell
podman build -t admin-toolbox:latest .
podman build --build-arg "BUILD_DATE=$(Get-Date -Format o)" -t admin-toolbox:latest .
podman build --no-cache -t admin-toolbox:latest .
podman run --rm -v ${PWD}:/work -w /work admin-toolbox:latest pwsh -NoProfile -File .\scripts\Verify-Toolbox.ps1
```

`Verify-Toolbox.ps1` is **not** baked into the image. Bind-mount the repo.

CI uses Docker Buildx on GitHub-hosted `ubuntu-latest` and must pass
verification, Betterleaks Git history scanning, and Trivy source and image
scans before pushing to GHCR.
Keep HIGH/CRITICAL findings (including unfixed ones) blocking unless a specific
reviewed exception policy is separately authorised. Scanner errors are failures.
Do not upload raw secret matches or image-config environment/history values.
Do not add a `pull_request` push-to-GHCR
job. Local workflow stays Podman; see [docs/BUILD.md](docs/BUILD.md).

Keep documentation in logical reading order; reordering is fine when it helps.
If files are renamed, moved or removed, check and update incoming links,
navigation, workflow references and literal filenames in the same change.

## Scope

Stick to the files the user names unless those files are not enough.
Small diffs. No extra markdown files for a one-line change.
