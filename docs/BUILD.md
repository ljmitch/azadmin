# Build, verify, scan and release

Day to day, pull the appropriate published profile rather than rebuilding every
time. [USAGE.md](USAGE.md) covers login and mounted projects;
[TOOLS.md](TOOLS.md) lists each tool and its install policy.

## 1. Select a profile

| Build argument | Result |
|---|---|
| `TOOLBOX_PROFILE=core` | Default Azure/M365 admin tools, without a standalone .NET SDK or Functions CLI |
| `TOOLBOX_PROFILE=dotnet` | Core plus the .NET 10 SDK |
| `TOOLBOX_PROFILE=functions` | Dotnet plus GA Azure Functions Core Tools v4 |

The Dockerfile's named stages form `core -> dotnet -> functions`; the final
stage selects the requested profile. This is
[multi-stage image construction](https://docs.docker.com/build/building/multi-stage/),
not installation controlled by an environment variable after startup. Select a
profile with the build argument, or pull that profile's published image.
The baked `TOOLBOX_PROFILE` identifies its contents for the verifier; overriding
it at run time does not change installed tools.

The images currently support Linux/amd64. Downloads include architecture-specific
binaries, and the Dockerfile rejects unsupported architectures. An emulated
amd64 run on another host is distinct from a native arm64 image.

## 2. Build a local candidate

Run these examples from this repository in host PowerShell:

```powershell
$profile = 'core' # core, dotnet, functions
$candidate = "admin-toolbox:$profile"
podman build --build-arg "TOOLBOX_PROFILE=$profile" -t $candidate .
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
```

Docker uses the same profile build argument. A basic build may reuse cached
floating-tool layers. For a deliberate refresh, pull the source images needed
by the selected profile and invalidate the installation layers:

```powershell
podman build --pull=always `
  --build-arg "TOOLBOX_PROFILE=$profile" `
  --build-arg "BUILD_DATE=$(Get-Date -Format o)" `
  -t $candidate .
if ($LASTEXITCODE -ne 0) { throw 'Fresh build failed' }
```

Docker's equivalent pull flag is `--pull`. `BUILD_DATE` cannot refresh an upstream
base image by itself. `--no-cache` bypasses instruction reuse but also needs a
pull flag when newer parent bytes are wanted. Exact image digest pins still
select the same parent until deliberately updated.

For GNU make users: `make build PROFILE=dotnet`, `make build-fresh PROFILE=functions`
and `make verify PROFILE=functions`. These shortcuts need GNU make, a POSIX
shell and a working Podman engine; the PowerShell commands above do not need make.

## 3. Verify the candidate that was built

```powershell
podman run --rm -v "${PWD}:/work:ro" -w /work $candidate `
  pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1 -ExpectedProfile $profile
if ($LASTEXITCODE -ne 0) { throw 'Verification failed' }
podman image inspect $candidate --format '{{.Size}}'
```

The verifier is not baked into the image. A rebuild plus this verifier is
required after changing the Dockerfile, installation script or verification
contract. Each profile must contain exactly its advertised optional tool set;
core must not silently inherit the standalone SDK or Core Tools.

Version and import checks are useful acceptance gates, not an application test.
For functions, compile and run the intended project, check its actual route or
trigger and validate dependencies. A local storage emulator is separate from
Azure identity or access to a real Service Bus namespace. Keep emulator and
application tests local unless an actual cloud operation is deliberately intended.

## 4. Scan before publishing

The workflow builds, verifies and scans a locally loaded artifact before pushing
that same image. It does not rebuild a different image for publication. Each
profile gets its own evidence and must satisfy the gate.

Trivy inspects the built image for OS/language vulnerabilities and secrets,
retains a complete vulnerability JSON report and SBOM, and blocks HIGH/CRITICAL
vulnerabilities as well as secret findings. Unfixed vulnerabilities are included.
Authentication, database-download and scanner execution errors fail the check;
they are not treated as clean results. See the checked-in scan script for the
pinned scanner version and exact flags.

[Trivy supports container image and archive targets](https://trivy.dev/docs/latest/guide/target/container_image/).
The scanner is a CI/local validation tool, not another always-installed toolbox
package. Local scan helpers require their documented container engine and shell;
PowerShell source parsing alone does not execute a scan.

Reports can contain sensitive paths or a detected credential. CI retains full
vulnerability JSON, a CycloneDX SBOM, tool/image metadata and sanitized secret
finding counts for seven days. It does not retain raw secret matches in artifacts
or print them in the job log. GitHub run artifacts follow repository/run access;
for a public repository, assume retained reports are visible to others. Use an
appropriately restricted local location for deeper secret investigation.
Rotate a detected secret and investigate its origin. Do not add blanket
ignores or `--ignore-unfixed` just to make this administrative toolbox green.
Where a genuine exception is needed, define its advisory/digest scope, owner,
rationale, compensating control and expiry as a separately reviewed policy change.

An SBOM is an inventory, not a signature or vulnerability decision. This workflow
retains evidence separately; it does not claim deployed signature enforcement or
registry-attached attestations. New advisories can affect an image after a passing
build, which is why refreshing and rescanning still matter.

## 5. Publish and consume a reviewed image

GitHub-hosted Ubuntu CI uses Docker Buildx. Local use stays Podman. PRs build
without registry credentials or publication rights. Publication is restricted
to the trusted main-branch path after successful checks. A branch validation
run is not permission to replace the released `latest` image.

The publisher runs on qualifying main-branch pushes and the Monday 04:00 UTC
refresh. Manual dispatch defaults to validation only; publication additionally
requires main and the explicit publish input. Non-main branch validation and PR
checks have no registry login/push. All three profiles must pass before any of
that run's images are published.

| Profile | Moving aliases | Unique run tag |
|---|---|---|
| core | `latest`, `core` | `run-<run-id>-<attempt>-core` |
| dotnet | `dotnet` | `run-<run-id>-<attempt>-dotnet` |
| functions | `functions` | `run-<run-id>-<attempt>-functions` |

The unique run tag distinguishes rebuilds and retries of the same source commit.
Registry write/deletion protection is a separate policy; retain the published
digest as the artifact identity. No date or source-SHA alias is advertised as an
immutable release.

The default profile becomes core after these changes are merged and the first
successful publication completes. Use `:functions` when you want the previous
all-in SDK/Core Tools capability; do not expect the new core default to build
Functions projects.

A release tag helps navigation; pin the approved `repository@sha256:...` reference
for exact repeatability. Neither a date tag nor a source SHA proves immutable
registry policy, and two builds of the same commit can resolve different floating
tool versions. Retain the actual digest, source commit, profile and build evidence.

A successful weekly refresh does not patch containers already running elsewhere.
Pull the approved replacement and recreate your toolbox session. Credential
volumes and project data have independent lifecycles and remain your responsibility.

## Source images and version policy

The workflow passes these repository variables explicitly as build arguments.
Local builds use Dockerfile defaults unless equivalent arguments are supplied:

| Variable / argument | Default | Scope |
|---|---|---|
| `BASE_IMAGE` | `ubuntu:24.04` | Core base, inherited by all profiles |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0-noble` | SDK source used only by dotnet/functions |
| `TOOLBOX_PROFILE` | `core` | Local profile selector; CI validates the declared profile set |
| `BUILD_DATE` | `unknown` | Deliberate installation-layer cache invalidation |
| `YQ_VERSION` | `latest` | Yq release selector |
| `HELM_VERSION` | `latest` | Helm release selector |

The compatible base remains Ubuntu 24.04 with the noble .NET 10 SDK for optional
SDK profiles. A new base release needs feed/native-library compatibility checks;
codename-derived URLs alone do not establish support.

| Component | Update policy |
|---|---|
| Ubuntu packages | `apt-get upgrade` and install during a fresh core build |
| PowerShell and Azure CLI | Current packages from their separate Microsoft feeds |
| Az / Graph / Exchange modules | Gallery latest at build; all Graph leaves installed together |
| Terraform | HashiCorp apt package; pinning requires a reviewed install-layer edit |
| Tflint | Upstream release with checksum verification |
| Checkov | Current pip release in an isolated virtual environment |
| Kubectl / kubelogin | Selected by `az aks install-cli` at build time |
| Yq / Helm | Latest release by default; version arguments can select reviewed releases |
| Azd / AzCopy | Current upstream installer/archive |
| PostgreSQL client | Current PGDG metapackage |
| Optional .NET SDK | Maintained .NET 10 noble source image |
| Optional Core Tools | GA v4 package from PMC |

Only the arguments above are implemented. There is no effective `TF_VERSION`,
`PWSH_VERSION`, `GRAPH_MODULE_VERSION` or `AZ_MODULE_VERSION` build argument.
To pin a different tool, change its supported installation mechanism and update
the verifier/inventory in the same review. Do not pin Graph leaves independently.
Floating feeds keep this personal toolbox convenient; retained artifacts and
version reports provide traceability rather than bit-for-bit reproducible builds.

## Validated profile candidates: 18 November 2026

All three profiles were rebuilt with Docker Desktop on Linux/amd64 and passed
the updated verifier without network access or credential mounts. The native
exit-code regression checks and all 21 scan-policy fixtures passed. A temporary
.NET 10 console project also restored, built and ran offline in the SDK profile.
This is local candidate evidence, not a claim about a published GHCR image.

| Profile | Unpacked bytes | Approximate GB | HIGH | CRITICAL | Secret findings |
|---|---:|---:|---:|---:|---:|
| core | 4,610,796,015 | 4.6 | 26 | 0 | 2 |
| dotnet | 5,512,782,026 | 5.5 | 26 | 0 | 2 |
| functions | 7,461,988,056 | 7.5 | 82 | 4 | 2 |

These are Docker image-inspect sizes, not compressed download sizes or a sum
of separately stored shared layers. Selecting core saves about 2.85 GB against
the full functions profile in this build. Trivy 0.76.2 used vulnerability DB
version 2, updated at 2026-11-18 13:03:23 UTC. Every image had a nonempty
CycloneDX inventory and a supported Ubuntu OS; source secret scanning found
zero matches. Findings count affected package/advisory records, not unique
exploits or a demonstration of exploitability.

**All three candidates fail the release policy.** The common HIGH findings
include dependencies bundled with current Azure CLI, azd, kubectl and kubelogin,
plus Checkov's python-ecdsa dependency. One setuptools record comes from vendor
SBOM metadata although the active installed package reports a newer version;
that discrepancy still needs review rather than an automatic waiver.

The Functions profile additionally bundles old .NET dependencies. Its four
CRITICAL records include the private `in-proc8` runtime: actual Kestrel, HTTP and
System.Net.Http binaries reported 8.0.4 in Core Tools package 4.16.1-1. Updating
the separate .NET 10 SDK does not patch those private files. Do not rewrite a
vendor dependency manifest or delete legacy workers merely to hide findings.
Track a supported upstream fix and retest the intended project.

The two secret findings are JWT-shaped samples in bundled Az.Attestation help.
They remain blocked for provenance review, rather than being classified as live
credentials or silently ignored. The unused TLS private key generated during
PostgreSQL package setup was removed in that same installation layer; rebuilt
images no longer contain that key or its certificate. Raw matched values and
local validation reports are excluded from Git and the build context.

Local checks also passed workflow actionlint, Bash syntax, PowerShell parsing
and documentation-link checks. Podman and GNU make were unavailable on the
review host, so their command examples were reviewed rather than executed.
The first hosted validation run is separate evidence. No registry publication
or Azure login/deployment was part of these local checks. See
[the recorded scan and verification failures](TROUBLESHOOTING.md#20-a-version-command-existed-but-verification-still-needed-to-fail).

## Historical full-image measurements

The following evidence predates optional profiles. It describes the
**2026-11-04** `admin-toolbox:functions-review` build, not a fresh result for this
revision or proof of the current published image:

- Ubuntu 24.04.5, .NET SDK 10.0.403, Core Tools 4.16.0 and PowerShell 7.6.9.
- Complete toolbox verification passed. A temporary .NET 10 HTTP function
  compiled/started and returned HTTP 200 using a separate local Azurite container.
- No Azure login, deployment, Service Bus operation or registry push was performed.
- Unpacked image size: 7,341,607,841 bytes (about 7.3 GB). SDK directory: about
  624 MiB. Core Tools directory: about 1.3 GiB.

Those directories explain why optional developer layers are useful. They are not
a measured new core-versus-functions delta: floated packages also change between
builds, and shared layers/compressed pulls have different sizes. Measure each
new profile after a successful build and retain the results with its evidence.

## Feed failures and dependency updates

PowerShell/Core Tools use the general PMC configuration feed. Azure CLI has its
own `repos/azure-cli` source. Do not remove the latter when repairing a PowerShell
package failure. New Ubuntu support and PMC availability can lag; retain the
known compatible base until a clean build verifies the proposed replacement.

If a PMC PowerShell package is unavailable, use a reviewed official universal
`.deb` as a deliberate temporary install-layer change, with its publisher checksum
or signature checks. Do not blindly copy an old patch URL. Keep the independent
Azure CLI feed intact. Prior failures are documented in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Dependabot proposes GitHub Actions updates. It does not update repository image
variables, apt-installed tools or Gallery modules. Keep version review separate
from automated publication and do not enable automatic merging merely because
smoke tests pass.

Before requiring a PR job through branch protection, check its trigger filters:
a path-filtered workflow may not start for documentation-only PRs. Workflow files
do not establish repository branch policies, package visibility or external
approval settings. Evidence artifacts have retention/storage and confidentiality
implications even when the scanner itself is open source.
