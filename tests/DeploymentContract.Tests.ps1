#Requires -Modules Pester

<#
    The two deployment paths and the runbook share one contract: the set of CR_* automation
    variables. Terraform and Bicep each write them, the runbook reads them, and nothing in the
    type system connects the three. Drift here fails silently - a variable the runbook reads but
    nothing writes just falls back to a default, and a variable written under a misspelled name is
    never read at all. Both are exactly the kind of bug that only shows up in production.

    So the names are asserted against each other rather than trusted.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    function Get-SettingName {
        # Every CR_* token in a tree, whatever the surrounding syntax.
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Filter)

        $files = Get-ChildItem -Path (Join-Path $script:RepoRoot $Path) -Filter $Filter -Recurse -File
        $names = foreach ($file in $files) {
            [regex]::Matches((Get-Content -Path $file.FullName -Raw), 'CR_[A-Za-z]+') | ForEach-Object { $_.Value }
        }
        return @($names | Sort-Object -Unique)
    }

    $script:Bicep = Get-SettingName -Path 'deploy' -Filter '*.bicep'
    $script:Terraform = Get-SettingName -Path 'infra' -Filter '*.tf'

    # The runbook asks for them without the prefix: Get-RunbookSetting -Name 'VaultName'.
    $runbook = Get-Content -Path (Join-Path $script:RepoRoot 'src' 'runbooks' 'Invoke-CredentialRotationRunbook.ps1') -Raw
    $script:Runbook = @(
        [regex]::Matches($runbook, "Get-RunbookSetting\s+-Name\s+'([A-Za-z]+)'") |
            ForEach-Object { 'CR_' + $_.Groups[1].Value } |
            Sort-Object -Unique
    )
}

Describe 'Automation variable contract' {

    It 'writes the same variables from Bicep as from Terraform' {
        # Compare-Object rather than two Should -Be, so a failure names the odd one out.
        $difference = Compare-Object -ReferenceObject $script:Terraform -DifferenceObject $script:Bicep
        $difference | Should -BeNullOrEmpty -Because "Terraform and Bicep must configure the runbook identically, but these differ: $(($difference | ForEach-Object { "$($_.InputObject) ($($_.SideIndicator))" }) -join ', ')"
    }

    It 'writes every variable the runbook reads' {
        $missing = @($script:Runbook | Where-Object { $_ -notin $script:Bicep })
        $missing | Should -BeNullOrEmpty -Because "the runbook reads these and no deployment writes them: $($missing -join ', ')"
    }

    It 'reads every variable the deployments write' {
        $unread = @($script:Bicep | Where-Object { $_ -notin $script:Runbook })
        $unread | Should -BeNullOrEmpty -Because "these are deployed and never read, so they configure nothing: $($unread -join ', ')"
    }

    It 'finds a contract at all' {
        # Guards the regexes themselves: a rename that breaks the extraction would otherwise make
        # every test above pass on two empty sets.
        $script:Bicep.Count | Should -BeGreaterThan 10
        $script:Terraform.Count | Should -BeGreaterThan 10
        $script:Runbook.Count | Should -BeGreaterThan 10
    }
}
