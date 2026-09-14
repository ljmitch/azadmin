# USAGE runbook

Day-to-day ways to run the toolbox. Everything assumes Windows PowerShell on
the host + Podman Desktop with its WSL2 machine running.

## Interactive session (most common)

From anywhere you want to work - usually a repo root - run:

```powershell
podman run -it --rm `
  -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  -v admin_graph:/root/.local/share/IdentityCache `
  -v admin_kube:/root/.kube `
  admin-toolbox:latest
```

You land in `pwsh` with `/work` bind-mounted to the host folder - edits made
inside the container land on the host immediately (same files, not copies).

What each flag is doing, one line each:

- `-it` - interactive TTY makes `pwsh` usable as your shell
- `--rm` - delete the container when you exit (image layers + named volumes
  persist; only the container's writable layer is destroyed)
- `-v ${PWD}:/work` - bind mount of the current Windows folder via the
  podman WSL2 VM
- `-w /work` - start in there
- 4x `-v admin_...` - named volumes that persist between runs
- `admin-toolbox:latest` - the image; choose a dated tag to pin a build

Single-line equivalent if backtick line-continuations misbehave on paste:

```powershell
podman run -it --rm -v ${PWD}:/work -w /work -v admin_az:/root/.azure -v admin_azps:/root/.Azure -v admin_graph:/root/.local/share/IdentityCache -v admin_kube:/root/.kube admin-toolbox:latest
```

## Login persistence options

The named volumes are the only mechanism that allows tokens to survive a
`--rm` container exit. Choose how much memory the container gets:

| Mode | Command shape | Effect |
|---|---|---|
| Full persistence (default) | the full Quickstart above | tokens survive container exit; re-login needed monthly/quarterly on token rotation |
| Fully stateless | mount only `/work` (see below) | tokens die with the container; fresh login every run |
| Partial persistence | drop just the mounts you don't care to persist, e.g. keep `admin_az`, drop `admin_graph` | some tools remember you, others don't |

### Fully stateless recipe

Guaranteed zero token carry-over between sessions. Use this for:

- hopping between tenants/clients without cross-contamination
- any environment you're not comfortable leaving cached credentials behind for
- when you want deterministic "log in fresh every time"

```powershell
podman run -it --rm -v ${PWD}:/work -w /work admin-toolbox:latest
```

`az login` / `Connect-AzAccount` / `Connect-MgGraph` still work normally
*during* the session - tokens land in `/root/.azure` etc. as usual, but
those paths are now inside the container's own writable layer, which `--rm`
deletes on `exit`. Nothing survives.

Note: kubeconfig also becomes ephemeral in this mode. Any `az aks
get-credentials` write vanishes on exit (safe; secrets don't linger).

### Partial persistence (mix-and-match)

Pick only the caches you want to persist. Any volume you omit gets its
tokens fresh each session:

```powershell
# Only persist az CLI and az PowerShell; Graph + kube fresh every time
podman run -it --rm -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  admin-toolbox:latest
```

## Managing those persisted credentials

```powershell
# Show all volumes podman has created for you
podman volume ls

# See the actual host path + metadata of one
podman volume inspect admin_graph

# Peek INSIDE a volume without starting the toolbox:
podman run --rm -v admin_graph:/c ubuntu:24.04 ls -la /c

# Wipe a specific credential cache (forces fresh login for that tool only)
podman volume rm admin_graph

# Wipe ALL toolbox credential caches (forces fresh login across the board)
podman volume rm admin_az admin_azps admin_graph admin_kube

# Nuclear sweep of every dangling volume on this machine (careful -
# this catches any other project's volumes too):
podman volume prune

# And confirm what you've got left
podman volume ls
```

> ⚠️ The named volumes contain real tokens (portal-refreshable sessions).
> Treat `podman volume ls` as a credential inventory for your machine. If
> the laptop is ever shared, wiped, or handed back, run the `volume rm`
> sweep first.

## Passkeys / interactive login from inside a container

Passkey auth does **not** need a browser *inside* the container. The
device-code flow punts the actual sign-in back to your host (or phone):

1. Container prints a code + `https://microsoft.com/devicelogin`
2. Open that URL in any browser on **any device that can reach your
   passkey** - Edge on the same laptop, so Windows Hello prompts appear
   exactly as they would for `portal.azure.com`.
3. Passkey handshake happens entirely host-side (or phone-side).
4. The container polls for the token; login completes in the terminal.

From inside the container, force device-code explicitly - interactive
browser is not available in Linux without a display:

```powershell
az login --use-device-code
Connect-AzAccount -UseDeviceAuthentication
Connect-MgGraph -UseDeviceAuthentication -Scopes "Sites.Read.All","Sites.ReadWrite.All"
```

If a tenant CA policy explicitly blocks device-code flows, this fails
cleanly at `devicelogin`. Not something the toolbox can override.

> **Stateless wrinkle:** in the stateless recipe above, you'll be doing
> this dance at the start of every session - that's the intended cost.

## One-shot command style

Run a single command/script without dropping into a shell (scriptable):

### Persisted-credential variant

```powershell
podman run --rm -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure -v admin_azps:/root/.Azure `
  -v admin_graph:/root/.local/share/IdentityCache `
  admin-toolbox:latest pwsh -NoProfile -File .\scripts\my-organiser.ps1
```

### Stateless one-shot

```powershell
podman run --rm -v ${PWD}:/work -w /work `
  admin-toolbox:latest pwsh -NoProfile -Command "
    az login --use-device-code;
    Get-AzSubscription
  "
```

(this prompts for device-code, runs, then wipes everything.)

## Shell-of-record workflows

| Workflow | Entry point |
|---|---|
| AKS cluster access | `az aks get-credentials -g <rg> -n <cluster>` → `kubectl get pods` (persists only if `admin_kube` mounted) |
| AKS `helm` day | same → `helm list -A` → `helm upgrade --install ...` (kubelogin-backed auth respects the same volume mount) |
| Quick Graph lookup | `Connect-MgGraph -UseDeviceAuthentication ...` → `Get-MgSite -All` → `Show-MgContext` |
| Terraform day | `terraform init && terraform plan` (cwd = your infra folder under /work) |
| Bicep day | `az deployment sub create --location uksouth --template-file main.bicep` |
| azd template pull | `azd init -t <template>` then `azd up` |
| Azure DevOps CLI ops | after `az login`, `az devops configure --defaults organization=https://dev.azure.com/<org>` then `az pipelines list --detect true` |
| Exchange | `Connect-ExchangeOnline` (interactive browser from host) after az-side device-code |
| Big blob copy | `azcopy copy "https://<src>..." "https://<dst>..." --recursive=true` |
| Look at versions | `Get-ToolboxVersions` |

## Profile helpers (preloaded inside the image)

- `Get-ToolboxVersions` - prints OS / pwsh / az / Az / Graph / Terraform / kubectl / helm versions
- `Enter-AzureContext <tenant>` - wrapped `az login` + `Connect-AzAccount` pair
- `Show-MgContext` - quick look at Connect-MgGraph scope + expiry

Edits to `config/powershell/Microsoft.PowerShell_profile.ps1` on the host
DO NOT auto-apply; rebuild the image to bake a new one, or mount over it:

```powershell
podman run -it --rm -v ${PWD}:/work -w /work `
  -v ${PWD}/config/powershell/Microsoft.PowerShell_profile.ps1:/root/.config/powershell/Microsoft.PowerShell_profile.ps1 `
  admin-toolbox:latest
```

## Look under the hood

```powershell
# Verify - mount the repo so the script is visible (no credential volumes needed)
podman run --rm -v ${PWD}:/work -w /work admin-toolbox:latest `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1

# What's on disk?
podman images admin-toolbox
podman volume ls

# Which version of a floating tool did this build actually resolve?
podman image inspect admin-toolbox:latest --format "{{json .Config.Labels}}"
podman image history admin-toolbox:latest --no-trunc | Select-String "Installing"
```

The second pair of commands helps when a floating build pulled a "latest"
that surprised you - build logs relayed the exact version the GitHub-API
resolver picked.

## Gotchas quick-reference

- Backticks in PowerShell run-on commands are line-continuation traps -
  paste single-line versions into unfamiliar shells
- `--rm` cleans the container only; **named volumes stick around
  indefinitely** unless you `podman volume rm` them. Don't assume "exited"
  means "gone."
- Bind mounts on WSL2 translate Windows↔Linux slowly for many small files;
  for big Terraform caches prefer working inside the container FS or a WSL folder
- Whatever you write **outside** `/work` and the named volumes vanishes
  at `--rm` exit. Write scripts/state to /work; let credentials path out
  via volumes only
- You can peek into / watch any volume live with
  `podman run --rm -v <name>:/v ubuntu:24.04 ls /v` - useful for seeing
  exactly what tokens a volume is holding
- In stateless mode with Graph big-scope requests (`Sites.FullControl.All`),
  consent prompts appear at first connect per tenant - if your flow depends
  on seamless rebinding to prior consent, full persistence is the safer mode
