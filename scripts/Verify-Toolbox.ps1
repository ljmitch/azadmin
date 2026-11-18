<#
.SYNOPSIS
    Verify the selected toolbox profile without logging in to cloud services.
.DESCRIPTION
    Checks native exit codes, usable version output, extension metadata and module
    imports. Development tools must match the baked profile. Bind-mount this repo
    read-only to /work; this script is not baked into the image. Smoke checks do
    not establish application or Azure acceptance. No credentials are needed.
#>
[CmdletBinding()]
param(
    [ValidateSet('core', 'dotnet', 'functions')]
    [string]$ExpectedProfile = $env:TOOLBOX_PROFILE,
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$failures = 0
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $results.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    if ($Passed) { Write-Host "PASS $Name - $Detail" }
    else {
        Write-Host "FAIL $Name - $Detail" -ForegroundColor Red
        $script:failures++
    }
}

function Invoke-CheckedNative {
    param([string]$Name, [string[]]$Arguments, [int[]]$AcceptedExitCodes = @(0))
    if (-not (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "$Name is not on PATH"
    }
    $output = @(& $Name @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AcceptedExitCodes) { throw "$Name exited $exitCode" }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Name returned no output" }
    return $text
}

function Test-Binary {
    param([string]$Name, [string[]]$Arguments, [int[]]$AcceptedExitCodes = @(0), [string]$Match)
    try {
        $text = Invoke-CheckedNative -Name $Name -Arguments $Arguments -AcceptedExitCodes $AcceptedExitCodes
        if ($Match -and $text -notmatch $Match) { throw 'Output did not match the expected tool/version' }
        $first = ($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        Add-Result $Name $true $first
    } catch { Add-Result $Name $false $_.Exception.Message }
}

function Test-Module {
    param([string]$Name)
    try {
        Import-Module $Name -ErrorAction Stop
        $module = Get-Module $Name
        if (-not $module) { throw 'Import did not load the requested module' }
        Add-Result $Name $true "$($module.Version)"
    } catch { Add-Result $Name $false $_.Exception.Message }
}

Write-Host '== Profile and shell =='
if (-not $ExpectedProfile) { throw 'ExpectedProfile or baked TOOLBOX_PROFILE is required' }
Add-Result 'profile' ($env:TOOLBOX_PROFILE -ceq $ExpectedProfile) "expected=$ExpectedProfile actual=$env:TOOLBOX_PROFILE"
Add-Result 'PowerShell' ($PSVersionTable.PSVersion.Major -eq 7) "$($PSVersionTable.PSVersion)"

Write-Host '== Native tools =='
try {
    $version = Invoke-CheckedNative az @('version', '--output', 'json') | ConvertFrom-Json -ErrorAction Stop
    if (-not $version.'azure-cli') { throw 'azure-cli version is missing' }
    Add-Result 'az' $true $version.'azure-cli'
} catch { Add-Result 'az' $false $_.Exception.Message }
Test-Binary pwsh @('--version') -Match '^PowerShell 7\.'
Test-Binary gh @('--version') -Match 'gh version'
Test-Binary git @('--version') -Match '^git version'
Test-Binary terraform @('version') -Match 'Terraform v'
Test-Binary tflint @('--version') -Match 'TFLint version'
Test-Binary checkov @('--version') -Match '\d+\.\d+\.\d+'
try {
    $client = Invoke-CheckedNative kubectl @('version', '--client=true', '--output=json') |
        ConvertFrom-Json -ErrorAction Stop
    $kubectlVersion = $client.clientVersion.gitVersion
    if ($kubectlVersion -notmatch '^v\d+\.\d+\.\d+') { throw 'kubectl client version is missing or invalid' }
    Add-Result 'kubectl' $true $kubectlVersion
} catch { Add-Result 'kubectl' $false $_.Exception.Message }
Test-Binary kubelogin @('--version') -Match '\d+\.\d+'
Test-Binary helm @('version', '--short') -Match 'v\d+\.'
Test-Binary yq @('--version') -Match 'version v\d+'
Test-Binary jq @('--version') -Match '^jq-'
Test-Binary azd @('version') -Match 'azd version'
Test-Binary azcopy @('--version') -Match 'azcopy version'
Test-Binary psql @('--version') -Match 'PostgreSQL'
Test-Binary dig @('-v') -Match 'DiG'
Test-Binary ping @('-V') -Match 'iputils'
# OpenBSD nc uses 1 for help on some releases; other commands must exit zero.
Test-Binary nc @('-h') -AcceptedExitCodes @(0, 1) -Match 'OpenBSD netcat|usage:'
Test-Binary traceroute @('--version') -Match 'traceroute'
Test-Binary ip @('-Version') -Match 'iproute2'
Test-Binary openssl @('version') -Match '^OpenSSL'
Test-Binary ssh @('-V') -Match 'OpenSSH'
Test-Binary nmap @('--version') -Match 'Nmap version'
Test-Binary tcpdump @('--version') -Match 'tcpdump version'
Test-Binary iperf3 @('--version') -Match 'iperf 3'

Write-Host '== Supporting commands (presence only) =='
foreach ($name in @(
    'curl', 'wget', 'unzip', 'zip', 'less', 'rsync', 'python3', 'nslookup', 'host',
    'ss', 'mtr', 'tcptraceroute', 'tracepath', 'fping', 'hping3', 'socat', 'ipcalc', 'whois'
)) {
    Add-Result $name ([bool](Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) 'installation check; no network probe performed'
}

Write-Host '== Development tools =='
if ($ExpectedProfile -in @('dotnet', 'functions')) {
    Test-Binary dotnet @('--list-sdks') -Match '(?m)^10\.0\.\d+\s+\['
} else {
    Add-Result 'dotnet absent' (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) 'core excludes the .NET SDK command'
}
if ($ExpectedProfile -eq 'functions') {
    Test-Binary func @('--version') -Match '(?m)^4\.\d+\.\d+'
} else {
    Add-Result 'func absent' (-not (Get-Command func -ErrorAction SilentlyContinue)) "$ExpectedProfile excludes Functions Core Tools"
}

Write-Host '== Azure CLI extensions and Bicep =='
foreach ($name in @('azure-devops', 'aks-preview', 'ssh')) {
    try {
        $extension = Invoke-CheckedNative az @('extension', 'show', '--name', $name, '--output', 'json') |
            ConvertFrom-Json -ErrorAction Stop
        if ($extension.name -ne $name -or -not $extension.version) { throw 'Extension metadata is missing or incorrect' }
        Add-Result "az extension $name" $true $extension.version
    } catch { Add-Result "az extension $name" $false $_.Exception.Message }
}
Test-Binary az @('bicep', 'version') -Match 'Bicep CLI version'

Write-Host '== PowerShell modules =='
foreach ($name in @(
    'Az.Accounts', 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users',
    'Microsoft.Graph.Users.Actions', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Applications',
    'Microsoft.Graph.Identity.SignIns', 'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Sites', 'Microsoft.Graph.Files', 'Microsoft.Graph.Mail', 'ExchangeOnlineManagement'
)) { Test-Module $name }

if ($ReportPath) {
    $report = [ordered]@{
        profile = $ExpectedProfile
        checked_at_utc = [DateTime]::UtcNow.ToString('o')
        failures = $failures
        checks = @($results.ToArray())
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}
if ($failures -gt 0) {
    Write-Host "VERIFY FAILED - $failures check(s) failed. Do not publish." -ForegroundColor Red
    exit 1
}
Write-Host 'VERIFY PASSED - profile smoke checks passed; image scanning remains required.' -ForegroundColor Green
exit 0
