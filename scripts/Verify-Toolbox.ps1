<#
.SYNOPSIS
    Smoke test for the azure-admin-toolbox image.
.DESCRIPTION
    Loads every expected binary + PowerShell module + az extension and reports
    the version. Any failure = broken image; do not promote the tag.

    Not baked into the image - bind-mount the repo:

      podman run --rm -v ${PWD}:/work -w /work admin-toolbox:latest pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1

    Native CLIs that print help and exit 1 (nc -h) must not fail the script;
    PSNativeCommandUseErrorActionPreference is turned off for that reason.
#>

$ErrorActionPreference = 'Stop'
# Version flags like `nc -h` exit 1; don't treat that as a missing binary.
$PSNativeCommandUseErrorActionPreference = $false
$failures = 0

function Test-Binary {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$VersionArg
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Host "  ✘ $Name - not on PATH" -ForegroundColor Red
        $script:failures++
        return
    }
    try {
        $out = & $Name $VersionArg 2>&1 | Select-Object -First 1
        Write-Host "  ✔ $Name - $out"
    } catch {
        Write-Host "  ✔ $Name - present"
    }
}

function Test-Module {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )
    try {
        Import-Module $Name -ErrorAction Stop
        $m = Get-Module $Name
        Write-Host "  ✔ $Name - $($m.Version)"
    } catch {
        Write-Host "  ✘ $Name - $($_.Exception.Message)" -ForegroundColor Red
        $script:failures++
    }
}

function Test-Extension {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )
    try {
        $ext = az extension show --name $Name 2>$null | ConvertFrom-Json -ErrorAction Stop
        Write-Host "  ✔ az extension $Name - $($ext.version)"
    } catch {
        Write-Host "  ✘ az extension $Name - not installed / $($_.Exception.Message)" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host "== Container =="
$osLine = (Get-Content /etc/os-release | Select-String '^PRETTY_NAME') -replace 'PRETTY_NAME=',''
Write-Host "  $($osLine.Trim('"'))"
Write-Host ""

Write-Host "== PowerShell =="
Write-Host "  pwsh - $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host ""

Write-Host "== Binaries =="

# az: 'az version' emits JSON; parse it properly instead of printing "{"
try {
    $azVer = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  ✔ az - $azVer"
} catch {
    Write-Host "  ✘ az - $($_.Exception.Message)" -ForegroundColor Red
    $failures++
}

Test-Binary -Name 'pwsh'     -VersionArg '--version'
Test-Binary -Name 'gh'       -VersionArg '--version'
Test-Binary -Name 'git'      -VersionArg '--version'
Test-Binary -Name 'terraform' -VersionArg 'version'
Test-Binary -Name 'tflint'   -VersionArg '--version'
Test-Binary -Name 'checkov'  -VersionArg '--version'
# kubectl 'version' (no args) tries to contact a cluster and errors out even on
# success - use --client=true
Test-Binary -Name 'kubectl'  -VersionArg 'version'
Test-Binary -Name 'kubelogin' -VersionArg '--version'
Test-Binary -Name 'helm'     -VersionArg 'version'
Test-Binary -Name 'yq'       -VersionArg '--version'
Test-Binary -Name 'jq'       -VersionArg '--version'
Test-Binary -Name 'azd'      -VersionArg 'version'
Test-Binary -Name 'azcopy'   -VersionArg '--version'
Test-Binary -Name 'psql'     -VersionArg '--version'
Test-Binary -Name 'dig'      -VersionArg '-v'
Test-Binary -Name 'ping'     -VersionArg '-V'
Test-Binary -Name 'nc'       -VersionArg '-h'
Test-Binary -Name 'traceroute'-VersionArg '--version'
Write-Host ""

Write-Host "== Azure CLI extensions =="
Test-Extension -Name 'azure-devops'
Test-Extension -Name 'aks-preview'
Test-Extension -Name 'ssh'
Write-Host ""

Write-Host "== Bicep =="
$bicepVersion = az bicep version 2>&1 | Select-String 'Bicep CLI version'
if ($bicepVersion) { Write-Host "  ✔ bicep - $($bicepVersion.ToString().Trim())" }
else { Write-Host "  ✘ bicep - not installed"; $failures++ }
Write-Host ""

Write-Host "== PowerShell modules =="
Test-Module -Name 'Az.Accounts'
Test-Module -Name 'Microsoft.Graph.Authentication'
Test-Module -Name 'Microsoft.Graph.Users'
Test-Module -Name 'Microsoft.Graph.Users.Actions'
Test-Module -Name 'Microsoft.Graph.Groups'
Test-Module -Name 'Microsoft.Graph.Applications'
Test-Module -Name 'Microsoft.Graph.Identity.SignIns'
Test-Module -Name 'Microsoft.Graph.Identity.DirectoryManagement'
Test-Module -Name 'Microsoft.Graph.Sites'
Test-Module -Name 'Microsoft.Graph.Files'
Test-Module -Name 'Microsoft.Graph.Mail'
Test-Module -Name 'ExchangeOnlineManagement'
Write-Host ""

if ($failures -gt 0) {
    Write-Host "VERIFY FAILED - $failures check(s) broken. Do not tag." -ForegroundColor Red
    exit 1
} else {
    Write-Host "VERIFY PASSED - image is good to tag." -ForegroundColor Green
    exit 0
}
