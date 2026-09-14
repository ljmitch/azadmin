<#
  azure-admin-toolbox pwsh profile
  Baked into /root/.config/powershell/ at build time from:
    repo-root:/config/powershell/Microsoft.PowerShell_profile.ps1
  Optional conveniences only - the image works fine without it.
#>

$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1
$env:POWERSHELL_TELEMETRY_OPTOUT = 1
$env:POWERSHELL_UPDATECHECK = 'Off'

# Handy helpers ----------------------------------------------------------------

function Get-ToolboxVersions {
    [PSCustomObject]@{
        BaseImage   = (Get-Content /etc/os-release | Where-Object {$_ -like 'PRETTY_NAME*'}).Split('"')[1]
        PowerShell  = $PSVersionTable.PSVersion
        AzCLI       = (az version --query '"azure-cli"' -o tsv 2>$null)
        AzModule    = (Get-Module Az -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
        GraphAuth   = (Get-Module Microsoft.Graph.Authentication -ListAvailable | Select-Object -First 1).Version
        GhCLI       = (gh --version 2>$null | Select-Object -First 1) -replace 'gh version ',''
        Azd         = (azd version 2>$null | Select-Object -First 1)
        AzCopy      = (azcopy --version 2>$null | Select-Object -First 1) -replace 'azcopy version ',''
        Terraform   = (terraform version -json 2>$null | ConvertFrom-Json).terraform_version
        Tflint      = (tflint --version 2>$null | Select-Object -First 1) -replace 'TFLint version ',''
        Kubectl     = (& kubectl version --client -o json 2>$null | ConvertFrom-Json).clientVersion.gitVersion
        Kubelogin   = (kubelogin --version 2>$null | Select-Object -First 1) -replace 'kubelogin version: ',''
        Helm        = (helm version --short 2>$null)
        Jq          = (jq --version 2>$null) -replace 'jq-',''
        Yq          = (yq --version 2>$null) -replace 'yq \(https://github.com/mikefarah/yq/\) version ',''
        Psql        = (psql --version 2>$null) -replace 'psql \(PostgreSQL\) ',''
    } | Format-List
}

function Enter-AzureContext {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string]$SubscriptionId
    )
    az login --tenant $TenantId --use-device-code | Out-Null
    if ($SubscriptionId) { az account set --subscription $SubscriptionId }
    Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -UseDeviceAuthentication
    Write-Host "Auth complete. Check with: az account show / Get-AzContext" -ForegroundColor Green
}

function Show-MgContext {
    $ctx = Get-MgContext
    if ($ctx) {
        $ctx | Format-List DisplayName, Scopes, Environment, ExpiresOn
    } else {
        Write-Host "No active MgGraph context. Connect with:" -ForegroundColor Yellow
        Write-Host "  Connect-MgGraph -UseDeviceAuthentication -Scopes `"Sites.Read.All`",`"Sites.ReadWrite.All`""
    }
}

function Show-ToolboxHints {
    Write-Host @"

azure-admin-toolbox quick reference:
  Get-ToolboxVersions    - what's actually in this image
  Enter-AzureContext     - az login + Connect-AzAccount for a tenant
  Show-MgContext         - current Graph session scopes + expiry

Remember the auth stance:
  - Inside the container: device-code flows only. No interactive browsers exist here.
  - az login --use-device-code
  - Connect-AzAccount -UseDeviceAuthentication
  - Connect-MgGraph -UseDeviceAuthentication -Scopes "..."

Volumes mounted today (listed alongside startup):
  $(if (Test-Path /root/.azure/state) { 'admin_az  ' } else { '' })$(if (Test-Path /root/.Azure) { 'admin_azps  ' } else { '' })$(if (Test-Path /root/.local/share/IdentityCache) { 'admin_graph  ' } else { '' })$(if (Test-Path /root/.kube) { 'admin_kube' } else { '' })
"@ -ForegroundColor Cyan
}

# Prompt: "[pwsh] path >" - plain and grep-friendly
function prompt {
    "[pwsh] $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
}
