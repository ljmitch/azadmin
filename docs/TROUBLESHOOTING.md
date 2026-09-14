# TROUBLESHOOTING

The war stories that shaped this image. Every entry earned its place;
add new ones as you hit them.

## 1. The original 5.1 `TypeLoadException` (why this repo exists)

**Symptom** - on Windows PowerShell 5.1:

```
Import-Module : Method 'GetTokenAsync' in type
'Microsoft.Graph.PowerShell.Authentication.Core.Utilities.UserProvidedTokenCredential'
from assembly 'Microsoft.Graph.Authentication.Core, Version=2.39.0.0 ...'
does not have an implementation.
```

**Cause** - Microsoft.Graph Authentication ≥ 2.34.0 broke loading under
Windows PowerShell 5.1 / .NET 4.8 (`TypeLoadException` against updated
Azure.Core token types). Regressed from 2.34 onwards; PS 7 is unaffected.
Upstream issue: microsoftgraph/msgraph-sdk-powershell#3479 (open).

**Fix in toolbox** - everything runs in PowerShell 7 (pwsh). On a Windows
5.1 host, pin Graph at 2.33.0 or migrate to pwsh.

## 2. Mixed Graph leaf versions → assembly hell

**Symptom** - alternating `TypeLoadException` / `FileNotFoundException` /
token-type mismatches across `Import-Module Microsoft.Graph.*`, even on pwsh 7.

**Cause** - installing two leaves at *different* `-RequiredVersion`s
(drifting one time, pinning another time by hand). Leaves share transitive
dependencies; mismatched versions produce partial-load states where exactly
the wrong assembly loads first.

**Fix in toolbox** - all Graph leaves install in one unpinned `Install-Module`
call so they resolve together at gallery latest. Do not add `-RequiredVersion`
per-leaf. Rebuild with `BUILD_DATE` when you want a fresh set.

## 3. PMC feed lag on new Ubuntu/Debian releases

**Symptom** - `Unable to locate package powershell` during `podman build`
straight after switching `FROM` to a new base.

**Cause** - Microsoft publishes the `powershell` apt package into
`packages.microsoft.com` per codename and usually lags a new release by weeks.

**Confirmed scar:** on 14-Sep-2026, two things happened that together showed
why this scar is subtle:

- A 26.04/resolute base built fine through most steps - confirmed *viable*.
- The same build died at a `RUN source /etc/os-release` line with
  `source: not found` - a dash/POSIX regression that *masked* whether PMC
  resolute actually had `powershell`. We never got a clean read.

So: 26.04 isn't confirmed-broken, it's confirmed-*unknown*, and this scar is
evidence you should distrust "works today" conclusions drawn from a build that
never reached the pwsh layer.

**Current policy:** base stays `ubuntu:24.04` (noble) where PMC noble feedback
is well-understood. Re-check the 26.04 feed monthly; flip to resolute when two
consecutive clean builds prove it carries `powershell`.

**Fix if you hit it again:** universal `.deb` fallback in BUILD.md; keep
azure-cli block intact.

## 4. `azure-cli` is NOT in the general PMC feed

**Symptom** - `E: Unable to locate package azure-cli` even though
`packages-microsoft-prod.deb` installed fine.

**Cause** - Azure CLI has its own apt feed:
`https://packages.microsoft.com/repos/azure-cli/`, suite keyed from the
codename-resolved variable. The PMC feed only carries PowerShell (etc.).

**Fix in toolbox** - separate azure-cli feed block in the Dockerfile.
Expect PMC to never deliver azure-cli.

## 5. PEP-668 `externally-managed-environment`

**Symptom** - `pip3 install checkov` fails with
`error: externally-managed-environment` on Ubuntu 24.04+ / Debian 12+.

**Cause** - PEP-668 hard-blocks pip's system-site-packages on modern
Debian/Ubuntu.

**Fix in toolbox** - `--break-system-packages` used deliberately
(single-purpose container). Alternative if strict posture is required:
`python3 -m venv /opt/checkov` + symlink. Enterprise-hosts hygiene note:
never use the flag on shared machines.

## 6. tflint upstream pulled the auto-install script (Sept 2026)

**Symptom** - `tflint --version` reports command-not-found despite the
`install_linux.sh | sh` line having built.

**Cause** - commit `cea78fd` (12-Sep-2026): terraform-linters removed
`install_linux.sh` from the repo. The pipe to `sh` was executing an
empty/404 response and reported success because `sh` happily executes nothing.

**Fix in toolbox** - manual install: zip + checksums.txt via
`sha256sum --ignore-missing -c`, unzip into `/usr/local/bin`. Download URL
is now `releases/latest/download/tflint_linux_amd64.zip` - floats by default;
pin via explicit `releases/download/vX.Y.Z/` URL if drift bites.

## 7. Module version drift across rebuilds

**Symptom** - import/runtime crashes against token types (`GetTokenAsync`,
accelerated-network data models…) even though "everything built".

**Cause** - floating `Install-Module` pulls module bundles at rebuild time;
mixing Az built in June with Graph built in September is a known
assembly-mismatch seed.

**Fix in toolbox** - Az, Graph, and ExchangeOnlineManagement float to gallery
latest in one build layer. Rebuild with `--build-arg BUILD_DATE=<ts>` (or
`--no-cache`) when you want today's gallery, not last week's cache. Do not
pin Graph leaves independently of each other.

## 8. OneDrive-synced module folders on the Windows host

**Symptom** - module files reappearing after uninstall; stale copies under
`Documents\PowerShell\Modules\`.

**Cause** - OneDrive "Known Folder Move" on corp machines co-locates
`Documents`.

**Fix** - uninstall all versions (`Uninstall-Module X -AllVersions`), prune
leftovers under both `PowerShell\Modules` and `WindowsPowerShell\Modules`,
then `Install-Module` again. In the container this is irrelevant.

## 9. Graph scopes need re-consent, not more `-Scopes` repetition

`Connect-MgGraph -Scopes "Sites.Read.All"` caches consent per session token.
Adding a scope later is additive - decide then, don't preempt:

```powershell
Disconnect-MgGraph
Connect-MgGraph -UseDeviceAuthentication -Scopes "Sites.Read.All","Sites.ReadWrite.All","Files.Read.All"
```

(`-UseDeviceAuthentication` is mandatory in the container; plain
`Connect-MgGraph` tries to launch a browser you don't have there.)

## 10. `/bin/sh: 1: source: not found`

**Symptom** - Docker/Podman RUN fails at `source /etc/os-release`.

**Cause** - RUN executes with `/bin/sh` (dash on Ubuntu), not bash; `source`
isn't POSIX. It will also happily fail *after* substantial earlier work,
so the failing layer isn't where the bug lives.

**Fix** - use `.` (dot). POSIX: `. /etc/os-release`. Or set
`SHELL ["/bin/bash", "-c"]` at the top of the Dockerfile if you really need
bash-only syntax elsewhere.

**Confirmed scar 14-Sep-2026** - hit exactly this during a noble build
port after an AI regenerated the PowerShell/PMC block. Cost: a full
13-minute rebuild to reach step 9 and watch it die there. Defensive habit:
after any big re-layout, run `podman build` on an intermediate tag and
eyeball the first ~30 lines out loud before walking away.

## 11. Ubuntu's `postgresql-client` is old

**Symptom** - `psql --version` reports something like 16.x on noble even
though you swear you installed the latest.

**Cause** - Ubuntu's own archive for noble ships pg client 16.x. Azure
Database for PostgreSQL targets commonly ship 17 new-major at time of
writing, and the pg client back-compat only goes so far forwards.

**Fix in toolbox** - bootstrap the PGDG apt feed via
`/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y` first
(installs `postgresql-common` ahead), then `apt-get install postgresql-client`
from the added repo pulls current upstream (18.x at time of writing).

## 12. pip-as-root warning: expected here

**Symptom** - build logs end with `WARNING: Running pip as the 'root' user...`

**Verdict** - informational in this image only. `--break-system-packages` +
root-on-single-purpose-container is the intentional posture; on shared
hosts the warning is correct. Do not chase it in the image; do not transplant
the pattern to hosts.

## 13. `az aks get-credentials` writes where?

To `/root/.kube/config` inside the container - **ephemeral** unless the
kubeconfig lives in a volume. Add `-v admin_kube:/root/.kube` to the run
line if you want cluster access to survive container exits (see USAGE.md).
If you're running in stateless mode this is working-as-intended.

## 14. `podman images --filter "tag=latest"` is invalid

**Symptom** - `Error: invalid image filter "tag": must be in the format
"filter=value or filter!=value"`.

**Cause** - podman's filter grammar uses `reference` (glob-accepting), not
`tag`. The intuitive spelling was taught by dockers' own help text but fetched
against a podman CLI, so they disagree.

**Fix** - `podman images --filter "reference=*:latest" ...`. The glob
`reference` filter is the podman spelling; `tag=` is not valid.

## 15. Locked-ACR pull failure masks other failures in a loop

**Symptom** - a `ForEach-Object { podman pull $_ }` refresh loop errors on
ONE registry (e.g. a network-restricted `<acr>.azurecr.io` with
`denied: client with IP ... not allowed access`) and the other pulls silently
don't happen.

**Cause** - the PowerShell pipeline keeps stepping through elements; what
actually stalls is your reason to finish.

**Fix** - the error is truthful and self-healing: re-run after either
(1) adding your client IP to the ACR allowlist, or (2) untagging + removing
the offending image locally, and the rest proceed. Expectable pattern for
any ACR-restricted image on a home-run refresh loop.

## 16. RPM vs DEB on Ubuntu: `.rpm` files won't install

**Symptom** - `Unable to locate package <something>.rpm` or
`dpkg-deb: error: not a deb format archive`.

**Cause** - RPM is a RedHat-family packaging format. Ubuntu uses DEB; they
don't cross-install.

**Fix** - look for the same tool's `.deb` or a binary tarball. If upstream
ships only RPM, either find a third-party PPA (tread carefully) or check if
they publish archives on their GitHub releases page (most tool ecosystems do,
yq/helm/tflint do).

## 17. The "file not found" trio that afflicts the download panel

If a freshly-saved file doesn't show up inside the container at the expected
path:

1. **Name drift** - files copied in from a download sometimes land as
   `scripts Verify-Toolbox.ps1` (folder name glued in), `Dockerfile.dockerfile`,
   or `thing.ps1.txt` (Windows Explorer hides extensions).
2. **Missing `config/powershell/` target** - the pwsh profile COPY only works
   if `Microsoft.PowerShell_profile.ps1` exists under `config/powershell/`
   in the repo root.
3. **Bind-mount paths are case-sensitive extensions** - `.txt` vs `.ps1`
   matters even if Explorer hides it.

Diagnose with `Get-ChildItem -Recurse .\scripts | Select Name` on the host;
re-check with `ls -la /work/<dir>` in the container.

## 18. `#` comments inside a backslash-continued `pwsh -Command "..."`

**Symptom** - `podman build` dies at the Graph `Install-Module` RUN with
`exit status 1` and no gallery error. A previous image may still show only
`Microsoft.Graph.Authentication` and `Microsoft.Graph.Sites`.

**Cause** - Dockerfile `\` continuation joins the pwsh string onto one line.
The first `# Get-MgUser...` then comments out the rest of that line, including
`Install-Module` itself. `$leaves` is truncated; the command parse-fails.

**Fix in toolbox** - the module layer is `scripts/Install-PsModules.ps1` run
with `pwsh -File`. Real newlines, so PowerShell comments stay comments. The
script throws if any named leaf is missing after install, so a partial gallery
pull cannot tag as success. Do not put `#` comments inside a backslash-continued
`pwsh -Command "..."` RUN.

## 19. `apt list --upgradable` inside a running container

**Symptom** - after `apt update`, three Ubuntu packages show as upgradable
(`base-files`, `libc6`, `libc-bin`) even though the image just built.

**Cause** - `FROM ubuntu:24.04` freezes those packages. `apt-get install` of
toolbox tools does not upgrade already-installed base packages. `apt update`
in a running container only refreshes indexes; `--rm` throws the upgrade away.

**Fix in toolbox** - the first apt `RUN` does `apt-get upgrade` after `update`.
A `BUILD_DATE` or `--no-cache` rebuild takes current noble-security. Do not
`apt upgrade` as a day-to-day habit inside the container.
