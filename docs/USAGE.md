# USAGE runbook

Day-to-day ways to run the toolbox. Host: Windows PowerShell + Podman Desktop
(WSL2 machine running). Image from CI:

```text
ghcr.io/ljmitch/azadmin:latest
```

Local builds use `admin-toolbox:core`, `admin-toolbox:dotnet` or
`admin-toolbox:functions` instead. Same flags; swap the name.

## Choose a profile first

After the updated workflow is merged and published, `:latest` / `:core` contain
the admin tools without a standalone .NET SDK. Choose `:dotnet` for .NET 10
builds, or `:functions` for the SDK plus Functions Core Tools v4. Until then,
build the corresponding local candidate using [BUILD.md](BUILD.md).

This is an image choice, not a runtime environment switch. Setting
`-e TOOLBOX_PROFILE=functions` on a core image does not install tools.
Containers created from the same functions image always retain its SDK bytes.

```powershell
podman build --build-arg TOOLBOX_PROFILE=functions -t admin-toolbox:functions .
podman run --rm -v "${PWD}:/work:ro" -w /work admin-toolbox:functions `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1 -ExpectedProfile functions
```

Use rootless Podman where supported. The container still runs as root inside
its own environment to preserve tool/cache conventions; it can modify any
writable workspace you mount. For inspection use `-v "${PWD}:/work:ro"`, keep
credential volumes separate by tenant/trust context and do not mount the host
Docker/Podman socket. Network capture tools may require specific capabilities;
that does not justify `--privileged` for the whole toolbox.

## Pull and run (copy / paste)

```powershell
podman pull ghcr.io/ljmitch/azadmin:latest
```

### Interactive session (credentials persist)

From anywhere you want to work - usually a repo root:

```powershell
podman run -it --rm `
  -v ${PWD}:/work -w /work `
  -v admin_az:/root/.azure `
  -v admin_azps:/root/.Azure `
  -v admin_kube:/root/.kube `
  ghcr.io/ljmitch/azadmin:latest
```

One line if backticks misbehave:

```powershell
podman run -it --rm -v ${PWD}:/work -w /work -v admin_az:/root/.azure -v admin_azps:/root/.Azure -v admin_kube:/root/.kube ghcr.io/ljmitch/azadmin:latest
```

Prefer the published digest for an exact artifact, or a retained profile/run
tag described in [BUILD.md](BUILD.md), rather than relying on a moving alias.
Swap `podman` for `docker` if that is your engine.

You land in `pwsh` with `/work` bind-mounted to the host folder - edits made
inside the container land on the host immediately (same files, not copies).

What each flag is doing, one line each:

- `-it` - interactive TTY makes `pwsh` usable as your shell
- `--rm` - delete the container when you exit (image layers + named volumes
  persist; only the container's writable layer is destroyed)
- `-v ${PWD}:/work` - bind mount of the current Windows folder via the
  podman WSL2 VM
- `-w /work` - start in there
- 3x `-v admin_...` - named volumes that persist between runs
- `ghcr.io/ljmitch/azadmin:latest` - moving CI alias; retain the published
  digest for exact identity, with a profile/run tag for navigation

## Login persistence options

These named volumes persist the selected tool caches beyond a `--rm` exit.
Other tools, custom cache locations and writes to `/work` need their own review.

| Mode | Command shape | Effect |
|---|---|---|
| Full persistence | the full Quickstart above | selected caches survive container exit; reauthentication follows tenant/tool policies |
| Fully stateless | mount only `/work` (see below) | default container caches are disposable; scripts can still write credentials to mounted files |
| Partial persistence | drop just the mounts you don't care to persist, e.g. keep `admin_az`, omit `admin_azps` | some tools remember you, others don't |

### Fully stateless recipe

No credential-volume mounts means the default tool caches are disposable.
This does not revoke sessions or erase anything a script writes to `/work`.
Use this for:

- hopping between tenants/clients without cross-contamination
- any environment you're not comfortable leaving cached credentials behind for
- when you want deterministic "log in fresh every time"

```powershell
podman run -it --rm -v ${PWD}:/work -w /work ghcr.io/ljmitch/azadmin:latest
```

`az login` / `Connect-AzAccount` / `Connect-MgGraph` still work normally
*during* the session - tokens land in `/root/.azure` etc. as usual, but
those paths are now inside the container's own writable layer, which `--rm`
deletes on `exit`. Avoid exporting tokens or moving cache locations into `/work`.

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
  ghcr.io/ljmitch/azadmin:latest
```

## Managing those persisted credentials

Graph uses `-ContextScope Process` in the recommended login recipe and logs in
again for each PowerShell session. The older `IdentityCache` mount was not its
cache location. Do not treat a mounted directory as proof that login persists.

For an intentionally configured persistent Graph session, Graph 2.39 uses both
`/root/.mg` (authentication record) and `/root/.local/share/.IdentityService`
(MSAL cache directory). Mount them to distinct dedicated volumes if required:

```powershell
podman run -it --rm -v "${PWD}:/work" -w /work `
  -v admin_graph_context:/root/.mg `
  -v admin_graph_tokens:/root/.local/share/.IdentityService `
  ghcr.io/ljmitch/azadmin:core
```

Secure persistence on Linux also needs a working keyring. A headless container
can fall back to process-only auth even with those mounts. Check
`(Get-MgContext).ContextScope` and test a new session before relying on persistence;
do not enable plaintext token storage as a convenience fix. See Microsoft's
[Graph authentication guidance](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands)
and the pinned [cache implementation](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.39.0/src/Authentication/Authentication.Core/Utilities/TokenCacheUtilities.cs).

```powershell
# Show all volumes podman has created for you
podman volume ls

# See the actual host path + metadata of one
podman volume inspect admin_graph_tokens

# Peek INSIDE a volume without starting the toolbox:
podman run --rm -v admin_graph_tokens:/c ubuntu:24.04 ls -la /c

# If the optional Graph volumes were used, remove both intentionally.
podman volume rm admin_graph_context admin_graph_tokens

# Remove selected toolbox caches after their containers have stopped.
podman volume rm admin_az admin_azps admin_kube

# And confirm what you've got left
podman volume ls
```

> ⚠️ The named volumes contain real tokens (portal-refreshable sessions).
> Treat `podman volume ls` as a credential inventory for your machine. If
> the laptop is ever shared, wiped, or handed back, run the `volume rm`
> sweep first.

## Passkeys / interactive login from inside a container

Device-code login uses a browser on the host or another device. The sign-in
methods offered depend on the tenant and Conditional Access policy. Do not
assume every passkey or authentication-strength policy accepts this flow:

1. Container prints a code + `https://microsoft.com/devicelogin`
2. Open that URL in any browser on **any device that can reach your
   permitted sign-in method** - for example, the browser on the same laptop.
3. Complete the sign-in method that the tenant permits.
4. The container polls for the token; login completes in the terminal.

From inside the container, force device-code explicitly - interactive
browser is not available in Linux without a display:

```powershell
az login --use-device-code
Connect-AzAccount -UseDeviceAuthentication
Connect-MgGraph -UseDeviceAuthentication -Scopes "User.Read" -ContextScope Process
Connect-ExchangeOnline -Device
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
  ghcr.io/ljmitch/azadmin:latest pwsh -NoProfile -File .\scripts\my-organiser.ps1
```

### Stateless one-shot

```powershell
podman run --rm -v ${PWD}:/work -w /work `
  ghcr.io/ljmitch/azadmin:latest pwsh -NoProfile -Command "
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
| Exchange | `Connect-ExchangeOnline -Device`; this is a separate tool login, not inherited from az |
| Big blob copy | `azcopy copy "https://<src>..." "https://<dst>..." --recursive=true` |
| Look at versions | `Get-ToolboxVersions` |

## Build a mounted .NET / Functions project

Use the `functions` profile, rebuilt and verified locally until published.
From the application project folder on the host, not this toolbox repo:

```powershell
podman run -it --rm --name admin-functions -p 127.0.0.1:7071:7071 `
  -v ${PWD}:/work/FunctionAppLab -w /work/FunctionAppLab `
  -v admin_nuget:/nuget/packages -e NUGET_PACKAGES=/nuget/packages `
  -v admin_func_bin:/work/FunctionAppLab/bin `
  -v admin_func_obj:/work/FunctionAppLab/obj `
  admin-toolbox:functions
```

Use `docker` instead of `podman` for Docker Desktop. The source is a live
writable bind mount. Linux bin/obj outputs are isolated from Windows builds;
use distinct volume names when switching between unrelated projects. No login
volumes are mounted in this example.

Inside the PowerShell container shell:

```powershell
dotnet --list-sdks
func --version
dotnet restore
dotnet build ./FunctionAppLab.csproj
dotnet publish ./FunctionAppLab.csproj --configuration Release --output ./artifacts/publish
```

Use the actual project filename. A repo's `global.json` still controls SDK
selection; check it against the container's SDKs rather than deleting it.
The publish output is under the source mount, so it remains on the host.

For local execution, configure host storage first. Azurite is intentionally
not inside this toolbox. Run its official image separately on a shared
container network and supply the explicit emulator blob/queue/table endpoints
in `AzureWebJobsStorage`. `UseDevelopmentStorage=true` alone points at the
toolbox's own loopback, not another container. A second container is not a
local Service Bus emulator.

Once storage and application settings are correct:

```powershell
dotnet run -- --address 0.0.0.0 --port 7071
```

From a host browser/terminal, call the application's actual route on
`http://localhost:7071`. Ctrl+C stops the host; `exit` leaves the main shell
and `--rm` removes the toolbox container. Source edits remain on the host;
NuGet/bin/obj volumes remain until deliberately removed. Azure logins are
separate from the host; use device-code login only when needed. An enabled
queue trigger can consume real messages as soon as the host starts.

## Profile helpers (preloaded inside the image)

- `Get-ToolboxVersions` - prints OS / pwsh / az / Az / Graph / Terraform / kubectl / helm versions
- `Enter-AzureContext <tenant>` - wrapped `az login` + `Connect-AzAccount` pair
- `Show-MgContext` - quick look at Connect-MgGraph scope + expiry

Edits to `config/powershell/Microsoft.PowerShell_profile.ps1` on the host
DO NOT auto-apply; rebuild the image to bake a new one, or mount over it:

```powershell
podman run -it --rm -v ${PWD}:/work -w /work `
  -v ${PWD}/config/powershell/Microsoft.PowerShell_profile.ps1:/root/.config/powershell/Microsoft.PowerShell_profile.ps1 `
  ghcr.io/ljmitch/azadmin:latest
```

## Look under the hood

```powershell
# Verify - mount the repo so the script is visible (no credential volumes needed)
podman run --rm -v ${PWD}:/work -w /work ghcr.io/ljmitch/azadmin:latest `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1

# What's on disk?
podman images ghcr.io/ljmitch/azadmin
podman volume ls

# Which version of a floating tool did this build actually resolve?
podman image inspect ghcr.io/ljmitch/azadmin:latest --format "{{json .Config.Labels}}"
podman image history ghcr.io/ljmitch/azadmin:latest --no-trunc | Select-String "Installing"
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
