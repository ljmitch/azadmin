<#
.SYNOPSIS
    Regression checks for the verifier's native-process failure handling.
.DESCRIPTION
    Loads only the verifier's function definitions and runs disposable pwsh
    child processes. Does not run toolbox checks, authenticate or access Azure.
#>
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$tokens = $null
$parseErrors = $null
$path = Join-Path $PSScriptRoot 'Verify-Toolbox.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Verifier has PowerShell syntax errors' }
foreach ($name in @('Add-Result', 'Invoke-CheckedNative', 'Test-Binary')) {
    $function = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false)
    if (-not $function) { throw "Missing function: $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
$results = [System.Collections.Generic.List[object]]::new()
$failures = 0
$executable = (Get-Process -Id $PID).Path

Test-Binary $executable @('-NoProfile', '-Command', 'Write-Output TEST_VERSION; exit 0') -Match 'TEST_VERSION'
if ($failures -ne 0 -or -not $results[0].passed) { throw 'Successful version command was rejected' }

Test-Binary $executable @('-NoProfile', '-Command', 'Write-Output TEST_VERSION; exit 7') -Match 'TEST_VERSION'
if ($failures -ne 1 -or $results[1].passed) { throw 'Nonzero native exit incorrectly passed verification' }

Test-Binary $executable @('-NoProfile', '-Command', 'exit 0')
if ($failures -ne 2 -or $results[2].passed) { throw 'Empty version output incorrectly passed verification' }

Test-Binary $executable @('-NoProfile', '-Command', 'Write-Output WRONG_OUTPUT; exit 0') -Match 'TEST_VERSION'
if ($failures -ne 3 -or $results[3].passed) { throw 'Invalid version output incorrectly passed verification' }

Test-Binary $executable @('-NoProfile', '-Command', 'Write-Output HELP_TEXT; exit 1') -AcceptedExitCodes @(0, 1) -Match 'HELP_TEXT'
if ($failures -ne 3 -or -not $results[4].passed) { throw 'Explicit help exit-code exception was rejected' }

Write-Host 'Verifier regression checks passed (three expected FAIL lines were tested).'
