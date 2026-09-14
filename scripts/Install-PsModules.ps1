<#
.SYNOPSIS
    Install Az + curated Microsoft.Graph leaves + ExchangeOnlineManagement.
.DESCRIPTION
    Build-time only (Dockerfile COPY + pwsh -File). Gallery latest.
    All Graph leaves go in one Install-Module so they resolve together;
    mixing -RequiredVersion per-leaf is the TypeLoadException scar
    (docs/TROUBLESHOOTING.md). Throws if any named leaf is missing so a
    partial install cannot succeed the layer.
    AllUsers scope is intentional inside the image; do not run this on a host.
#>
$ErrorActionPreference = 'Stop'

Set-PSRepository PSGallery -InstallationPolicy Trusted

$leaves = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Users.Actions'
    'Microsoft.Graph.Groups'
    'Microsoft.Graph.Applications'
    'Microsoft.Graph.Identity.SignIns'
    'Microsoft.Graph.Identity.DirectoryManagement'
    'Microsoft.Graph.Sites'
    'Microsoft.Graph.Files'
    'Microsoft.Graph.Mail'
)

Install-Module -Name $leaves -Scope AllUsers -Force -AllowClobber
Install-Module Az -Scope AllUsers -Force -AllowClobber
Install-Module ExchangeOnlineManagement -Scope AllUsers -Force -AllowClobber

Write-Host 'Graph leaf versions installed:'
Get-Module Microsoft.Graph.* -ListAvailable | Sort-Object Name | Format-Table Name, Version

$missing = $leaves | Where-Object { -not (Get-Module $_ -ListAvailable) }
if ($missing) {
    throw "Graph modules failed to install: $($missing -join ', ')"
}
if (-not (Get-Module Az.Accounts -ListAvailable)) {
    throw 'Az module failed to install (Az.Accounts missing)'
}
