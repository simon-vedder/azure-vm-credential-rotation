<#
.SYNOPSIS
    Flattens the CredentialRotation module and the runbook wrapper into one file.

.DESCRIPTION
    Azure Automation executes a single script per job. Importing a module would mean
    publishing it to the PowerShell Gallery or uploading it as a module asset from a
    storage account - both add a distribution step and a version to keep in sync for
    no benefit at this size.

    So the source stays a proper module: one function per file, testable with Pester,
    loadable locally with Import-Module. This script concatenates it into the single
    file that Terraform deploys. The output is committed to the repository so the
    infrastructure can be deployed without a build step.

    The one subtlety: a param() block must be the first statement in a script, so the
    wrapper's parameters cannot simply be appended after the function definitions.
    The wrapper is split on its parameter block using the language parser, and the
    parts are reassembled in a legal order.

.EXAMPLE
    ./build/Build-Runbook.ps1
    ./build/Build-Runbook.ps1 -Check      # fail if dist/ is stale, used in CI
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..' 'dist' 'Invoke-CredentialRotation.runbook.ps1'),

    # Verify the committed artefact matches the sources instead of writing it.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$moduleRoot = Join-Path $root 'src' 'CredentialRotation'
$runbookPath = Join-Path $root 'src' 'runbooks' 'Invoke-CredentialRotationRunbook.ps1'

foreach ($path in @($moduleRoot, $runbookPath)) {
    if (-not (Test-Path $path)) { throw "Not found: $path" }
}

$manifest = Import-PowerShellDataFile -Path (Join-Path $moduleRoot 'CredentialRotation.psd1')

# --- split the wrapper on its param block ----------------------------------

$tokens = $null
$errors = $null
$runbookAst = [System.Management.Automation.Language.Parser]::ParseFile($runbookPath, [ref]$tokens, [ref]$errors)

if ($errors.Count -gt 0) {
    throw "Runbook wrapper does not parse: $($errors[0].Message)"
}
if (-not $runbookAst.ParamBlock) {
    throw "Runbook wrapper has no param() block. The build assumes one exists."
}

$runbookText = Get-Content -Path $runbookPath -Raw
$paramExtent = $runbookAst.ParamBlock.Extent

$runbookHelp = $runbookText.Substring(0, $paramExtent.StartOffset).TrimEnd()
$runbookParams = $paramExtent.Text
$runbookBody = $runbookText.Substring($paramExtent.EndOffset).TrimStart()

# Requires statements are hoisted; keep exactly one in the generated file.
$runbookHelp = ($runbookHelp -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#Requires' }) -join "`n"

# --- assemble ---------------------------------------------------------------

$builder = [System.Text.StringBuilder]::new()

[void]$builder.AppendLine(@"
<#
    GENERATED FILE - DO NOT EDIT

    Built from src/ by build/Build-Runbook.ps1.
    Edit the module under src/CredentialRotation or the wrapper under src/runbooks,
    then rebuild and commit the result.

    Module version: $($manifest.ModuleVersion)
#>

#Requires -Version 7.2
"@)

[void]$builder.AppendLine($runbookHelp)
[void]$builder.AppendLine($runbookParams)
[void]$builder.AppendLine()

foreach ($folder in @('Private', 'Public')) {
    $files = Get-ChildItem -Path (Join-Path $moduleRoot $folder) -Filter '*.ps1' | Sort-Object Name

    [void]$builder.AppendLine("#region $folder")
    [void]$builder.AppendLine()

    foreach ($file in $files) {
        $dashes = '-' * [Math]::Max(3, 62 - $folder.Length - $file.Name.Length)
        [void]$builder.AppendLine("# --- $folder/$($file.Name) $dashes")
        [void]$builder.AppendLine((Get-Content -Path $file.FullName -Raw).TrimEnd())
        [void]$builder.AppendLine()
    }

    [void]$builder.AppendLine("#endregion $folder")
    [void]$builder.AppendLine()
}

[void]$builder.AppendLine('#region runbook')
[void]$builder.AppendLine()
[void]$builder.AppendLine($runbookBody.TrimEnd())
[void]$builder.AppendLine()
[void]$builder.AppendLine('#endregion runbook')

$content = ($builder.ToString() -replace "`r`n", "`n").TrimEnd() + "`n"

# --- verify the result is valid PowerShell ---------------------------------

$genErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$genErrors)
if ($genErrors.Count -gt 0) {
    throw "Generated runbook does not parse: $($genErrors[0].Message) at line $($genErrors[0].Extent.StartLineNumber)"
}

# --- write or check ---------------------------------------------------------

if ($Check) {
    if (-not (Test-Path $OutputPath)) {
        throw 'dist/ artefact is missing. Run ./build/Build-Runbook.ps1'
    }

    $existing = ((Get-Content -Path $OutputPath -Raw) -replace "`r`n", "`n").TrimEnd()
    if ($existing -ne $content.TrimEnd()) {
        throw 'dist/ artefact is out of date. Run ./build/Build-Runbook.ps1 and commit the result.'
    }

    Write-Host 'dist/ artefact is up to date.' -ForegroundColor Green
    return
}

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) { $null = New-Item -ItemType Directory -Path $outputDir -Force }

Set-Content -Path $OutputPath -Value $content -NoNewline -Encoding utf8
Write-Host "Wrote $OutputPath ($([Math]::Round($content.Length / 1kb, 1)) KB)" -ForegroundColor Green
