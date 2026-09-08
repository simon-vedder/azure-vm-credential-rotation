#Requires -Modules Pester

<#
    Unit tests for the parts that can be tested without Azure.

    The generators and the name resolver are pure, so they get real assertions. The
    Key Vault interaction is tested through mocks, focused on the one behaviour that
    matters most: never confusing "this secret does not exist" with "I cannot read
    this secret", because that confusion is what causes lockouts.
#>

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'src' 'AzureVMCredentialRotation'

    # Az is not installed in CI, so stub the cmdlets that get mocked. Pester cannot
    # mock a command that does not exist.
    function Get-AzKeyVaultSecret { param($VaultName, $Name, $ErrorAction) }
    function Invoke-AzOperationalInsightsQuery { param($WorkspaceId, $Query, $ErrorAction) }
    function Update-AzKeyVaultSecret { param($VaultName, $Name, $Expires, $Tag, $ErrorAction) }

    foreach ($folder in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:ModuleRoot $folder) -Filter '*.ps1' | ForEach-Object {
            . $_.FullName
        }
    }
}

Describe 'New-RotationPassword' {

    It 'returns a SecureString of the requested length' {
        $secure = New-RotationPassword -Length 24
        $secure | Should -BeOfType [securestring]
        (ConvertFrom-SecureString -SecureString $secure -AsPlainText).Length | Should -Be 24
    }

    It 'satisfies complexity in every sample' {
        # Complexity comes from drawing one character per class and shuffling, so it
        # must hold for every draw rather than on average.
        1..100 | ForEach-Object {
            $plain = ConvertFrom-SecureString -SecureString (New-RotationPassword -Length 16) -AsPlainText

            $plain | Should -Match '[a-z]'
            $plain | Should -Match '[A-Z]'
            $plain | Should -Match '[0-9]'
            $plain | Should -Match '[^a-zA-Z0-9]'
        }
    }

    It 'does not put the guaranteed characters at fixed positions' {
        # The predecessor inserted 'a','A','1','!' at offsets 0-3. If that regressed,
        # the first four positions would show almost no variety.
        $firstChars = 1..80 | ForEach-Object {
            (ConvertFrom-SecureString -SecureString (New-RotationPassword -Length 20) -AsPlainText)[0]
        }

        ($firstChars | Select-Object -Unique).Count | Should -BeGreaterThan 10
    }

    It 'excludes characters that travel badly through shells and JSON' {
        1..50 | ForEach-Object {
            $plain = ConvertFrom-SecureString -SecureString (New-RotationPassword) -AsPlainText
            $plain | Should -Not -Match '["\\`$ ]'
        }
    }

    It 'excludes visually ambiguous characters' {
        # -CMatch, not -Match: PowerShell's -match is case-insensitive, so a test for
        # lowercase l would also reject the perfectly fine uppercase L.
        1..50 | ForEach-Object {
            $plain = ConvertFrom-SecureString -SecureString (New-RotationPassword) -AsPlainText
            $plain | Should -Not -CMatch '[lIO01]'
        }
    }

    It 'never repeats a password' {
        $set = 1..200 | ForEach-Object {
            ConvertFrom-SecureString -SecureString (New-RotationPassword) -AsPlainText
        }
        ($set | Select-Object -Unique).Count | Should -Be 200
    }

}

Describe 'Get-UniformChar' {

    It 'draws without modulo bias' {
        # This is where bias would live, so test it here rather than through
        # New-RotationPassword - that function draws one character per class before
        # filling from the full alphabet, which skews the mix by design and would
        # mask what this test is looking for.
        #
        # With 86 characters and a naive $byte % 86, the 256 byte values map onto
        # 0..85 unevenly: remainders 0-83 occur three times, 84 and 85 only twice.
        # The tail of the alphabet would therefore appear about a third less often.
        $alphabet = -join ([char]'!'..[char]'~' | ForEach-Object { [char]$_ })[0..85]
        $draws = 12000

        $counts = @{}
        1..$draws | ForEach-Object {
            $c = Get-UniformChar -Alphabet $alphabet
            $counts[$c] = ($counts[$c] ?? 0) + 1
        }

        $expected = $draws / $alphabet.Length
        $tail = $alphabet.Substring($alphabet.Length - 2).ToCharArray()
        $tailAverage = ($tail | ForEach-Object { $counts[$_] ?? 0 } | Measure-Object -Average).Average

        # A biased implementation lands near 0.67 of expected here.
        ($tailAverage / $expected) | Should -BeGreaterThan 0.8
        ($tailAverage / $expected) | Should -BeLessThan 1.2
    }

    It 'only ever returns characters from the alphabet' {
        1..500 | ForEach-Object {
            Get-UniformChar -Alphabet 'abc' | Should -BeIn @('a', 'b', 'c')
        }
    }
}

Describe 'New-RotationSshKeyPair' {

    BeforeAll {
        $script:pair = New-RotationSshKeyPair -KeySize 2048
        $script:pem = ConvertFrom-SecureString -SecureString $script:pair.PrivateKey -AsPlainText
    }

    It 'produces a PKCS#8 PEM block' {
        $script:pem | Should -Match '^-----BEGIN PRIVATE KEY-----'
        $script:pem.TrimEnd() | Should -Match '-----END PRIVATE KEY-----$'
    }

    It 'uses LF line endings only' {
        # Base64FormattingOptions::InsertLineBreaks emits CRLF. Mixing that with
        # LF-terminated headers produces a PEM some OpenSSH clients reject.
        $script:pem | Should -Not -Match "`r"
    }

    It 'wraps base64 at 64 characters' {
        $body = $script:pem -split "`n" | Where-Object { $_ -and $_ -notmatch '^-----' }
        $body | Select-Object -SkipLast 1 | ForEach-Object { $_.Length | Should -Be 64 }
    }

    It 'produces an ssh-rsa public key' {
        $script:pair.PublicKey | Should -Match '^ssh-rsa [A-Za-z0-9+/]+=*$'
    }

    It 'encodes the public key so ssh-keygen derives the same value' -Skip:(-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        # The real test: ssh-keygen has to be able to read our PEM at all, and the key
        # it derives has to match the one we assembled by hand from the wire format.
        $keyFile = Join-Path ([System.IO.Path]::GetTempPath()) "rotation-test-$([guid]::NewGuid()).key"
        try {
            Set-Content -Path $keyFile -Value $script:pem -NoNewline
            if ($IsLinux -or $IsMacOS) { chmod 600 $keyFile }

            $derived = (ssh-keygen -y -f $keyFile) -join ''
            $LASTEXITCODE | Should -Be 0

            $derivedParts = $derived -split '\s+'
            $ourParts = $script:pair.PublicKey -split '\s+'

            $derivedParts[0] | Should -Be $ourParts[0]
            $derivedParts[1] | Should -Be $ourParts[1]
        }
        finally {
            Remove-Item -Path $keyFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'generates a different key each time' {
        $other = New-RotationSshKeyPair -KeySize 2048
        $other.PublicKey | Should -Not -Be $script:pair.PublicKey
    }
}

Describe 'ConvertFrom-PemToSshPublicKey' {

    It 'recovers the public key from the private key alone' {
        # Resuming an interrupted rotation has only the staged private key to work
        # from. The public key cannot be stored beside it: Key Vault caps a tag value
        # at 256 characters and an ssh-rsa key is several times that, which a live
        # vault rejects with "Property has invalid value".
        $pair = New-RotationSshKeyPair -KeySize 2048
        ConvertFrom-PemToSshPublicKey -PrivateKeyPem $pair.PrivateKey | Should -Be $pair.PublicKey
    }

    It 'is stable across repeated derivations' {
        $pair = New-RotationSshKeyPair -KeySize 2048
        $first = ConvertFrom-PemToSshPublicKey -PrivateKeyPem $pair.PrivateKey
        $second = ConvertFrom-PemToSshPublicKey -PrivateKeyPem $pair.PrivateKey
        $first | Should -Be $second
    }
}

Describe 'Resolve-SecretName' {

    It 'builds the documented shape' {
        Resolve-SecretName -VMName 'vm01' -AdminUsername 'azureadmin' -Kind 'pw' |
            Should -Be 'vm01-azureadmin-pw'
    }

    It 'adds the pending suffix' {
        Resolve-SecretName -VMName 'vm01' -AdminUsername 'azureadmin' -Kind 'pw' -Pending |
            Should -Be 'vm01-azureadmin-pw-pending'
    }

    It 'replaces characters Key Vault does not allow' {
        $name = Resolve-SecretName -VMName 'vm_01.prod' -AdminUsername 'corp\admin' -Kind 'ssh-priv'
        $name | Should -Match '^[a-zA-Z0-9-]+$'
    }

    It 'collapses runs of dashes' {
        Resolve-SecretName -VMName 'vm__01' -AdminUsername 'ad' -Kind 'pw' | Should -Not -Match '--'
    }

    It 'stays within the 127 character limit and stays unique' {
        $long = 'a' * 120
        $first = Resolve-SecretName -VMName $long -AdminUsername 'administrator' -Kind 'pw'
        $second = Resolve-SecretName -VMName ($long + 'b') -AdminUsername 'administrator' -Kind 'pw'

        $first.Length | Should -BeLessOrEqual 127
        $second.Length | Should -BeLessOrEqual 127
        $first | Should -Not -Be $second
    }

    It 'gives password and ssh key distinct names for the same VM' {
        $pw = Resolve-SecretName -VMName 'vm01' -AdminUsername 'ad' -Kind 'pw'
        $ssh = Resolve-SecretName -VMName 'vm01' -AdminUsername 'ad' -Kind 'ssh-priv'
        $pw | Should -Not -Be $ssh
    }
}

Describe 'Get-RotationSecret' {

    It 'reports a missing secret as absent' {
        Mock Get-AzKeyVaultSecret { return $null }

        $result = Get-RotationSecret -VaultName 'kv' -Name 'nope'
        $result.Exists | Should -BeFalse
    }

    It 'reports an existing secret as present' {
        Mock Get-AzKeyVaultSecret { return [pscustomobject]@{ Name = 'x'; Version = 'v1' } }

        $result = Get-RotationSecret -VaultName 'kv' -Name 'x'
        $result.Exists | Should -BeTrue
        $result.Secret.Version | Should -Be 'v1'
    }

    It 'throws rather than reporting absence when access is denied' {
        # The important one. Treating a 403 as "no secret, therefore rotate" is what
        # leads to changing a VM password and then failing to store it.
        Mock Get-AzKeyVaultSecret { throw 'Operation returned an invalid status code (Forbidden)' }

        { Get-RotationSecret -VaultName 'kv' -Name 'x' } | Should -Throw -ExpectedMessage '*Refusing to treat this as a missing secret*'
    }

    It 'throws rather than reporting absence when throttled' {
        Mock Get-AzKeyVaultSecret { throw 'Too many requests (429)' }

        { Get-RotationSecret -VaultName 'kv' -Name 'x' } | Should -Throw
    }

    It 'treats an explicit SecretNotFound as absent' {
        Mock Get-AzKeyVaultSecret { throw 'SecretNotFound: the secret was not found' }

        $result = Get-RotationSecret -VaultName 'kv' -Name 'x'
        $result.Exists | Should -BeFalse
    }
}

Describe 'Get-AccessedSecret' {

    It 'returns nothing when no reads are found' {
        Mock Invoke-AzOperationalInsightsQuery { return [pscustomobject]@{ Results = @() } }

        (Get-AccessedSecret -WorkspaceId 'ws' -VaultName 'kv').Count | Should -Be 0
    }

    It 'projects the query result' {
        Mock Invoke-AzOperationalInsightsQuery {
            return [pscustomobject]@{
                Results = @(
                    [pscustomobject]@{
                        SecretName     = 'vm01-admin-pw'
                        LastAccessedAt = '2026-07-31T09:15:00Z'
                        AccessedBy     = 'someone@example.com'
                        AccessCount    = '2'
                    }
                )
            }
        }

        $result = @(Get-AccessedSecret -WorkspaceId 'ws' -VaultName 'kv')

        $result.Count | Should -Be 1
        $result[0].SecretName | Should -Be 'vm01-admin-pw'
        $result[0].AccessCount | Should -Be 2
        $result[0].LastAccessedAt | Should -BeOfType [datetime]
    }

    It 'filters to the requested vault and excludes given object ids' {
        $script:capturedQuery = $null
        Mock Invoke-AzOperationalInsightsQuery {
            $script:capturedQuery = $Query
            return [pscustomobject]@{ Results = @() }
        }

        Get-AccessedSecret -WorkspaceId 'ws' -VaultName 'my-vault' -ExcludeObjectId @('abc-123') | Out-Null

        $script:capturedQuery | Should -Match "my-vault"
        $script:capturedQuery | Should -Match "abc-123"
        $script:capturedQuery | Should -Match "SecretGet"
        # Application identities must not trigger rotation.
        $script:capturedQuery | Should -Match "isnotempty\(Upn\)"
    }
}

Describe 'New-RotationRecord' {

    It 'carries no credential material' {
        $record = New-RotationRecord -SecretName 'vm01-admin-pw' -VMName 'vm01' `
            -ResourceGroupName 'rg' -SubscriptionId 'sub' -OSType 'Windows' `
            -CredentialType 'Password' -TriggerReason 'Access' -Result 'Rotated' `
            -NewSecretVersion 'abc123'

        $properties = $record.PSObject.Properties.Name
        $properties | Should -Not -Contain 'SecretValue'
        $properties | Should -Not -Contain 'Password'
        $record.NewSecretVersion | Should -Be 'abc123'
    }

    It 'emits round-trippable timestamps' {
        $record = New-RotationRecord -SecretName 's' -VMName 'v' -ResourceGroupName 'rg' `
            -SubscriptionId 'sub' -OSType 'Linux' -CredentialType 'SSHKey' `
            -TriggerReason 'Expiry' -Result 'Rotated'

        { [datetime]::Parse($record.TimeGenerated) } | Should -Not -Throw
        { [datetime]::Parse($record.StartedAt) } | Should -Not -Throw
    }

    It 'rejects a result value the custom table does not know' {
        { New-RotationRecord -SecretName 's' -VMName 'v' -ResourceGroupName 'rg' `
            -SubscriptionId 'sub' -OSType 'Linux' -CredentialType 'SSHKey' `
            -TriggerReason 'Expiry' -Result 'Something' } | Should -Throw
    }
}

Describe 'Resolve-TargetVM' {

    BeforeAll {
        function Get-AzVM { param($Name, $ResourceGroupName, $ErrorAction) }
    }

    It 'says which resource groups an ambiguous name is in' {
        Mock Get-AzVM {
            @(
                [pscustomobject]@{ Name = 'jump-01'; ResourceGroupName = 'rg-a' }
                [pscustomobject]@{ Name = 'jump-01'; ResourceGroupName = 'rg-b' }
            )
        }

        # Picking the first match would rotate a credential on a machine nobody named.
        { Resolve-TargetVM -Name 'jump-01' } | Should -Throw -ExpectedMessage '*rg-a, rg-b*'
    }

    It 'says the name was not found rather than returning nothing' {
        Mock Get-AzVM { @() }
        { Resolve-TargetVM -Name 'nope' } | Should -Throw -ExpectedMessage "*No VM named 'nope'*"
    }

    It 'fetches the machine again by resource group, because the list form has no OSProfile' {
        Mock Get-AzVM -ParameterFilter { $null -eq $ResourceGroupName } -MockWith {
            @([pscustomobject]@{ Name = 'jump-01'; ResourceGroupName = 'rg-a' })
        }
        Mock Get-AzVM -ParameterFilter { $ResourceGroupName -eq 'rg-a' } -MockWith {
            [pscustomobject]@{ Name = 'jump-01'; ResourceGroupName = 'rg-a'; OSProfile = @{ AdminUsername = 'azureuser' } }
        }

        $vm = Resolve-TargetVM -Name 'jump-01'

        $vm.OSProfile.AdminUsername | Should -Be 'azureuser'
        Should -Invoke Get-AzVM -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-a' }
    }

    It 'does not search the subscription when the resource group is given' {
        Mock Get-AzVM { [pscustomobject]@{ Name = 'jump-01'; ResourceGroupName = 'rg-a' } }
        $null = Resolve-TargetVM -Name 'jump-01' -ResourceGroupName 'rg-a'
        Should -Invoke Get-AzVM -Times 1 -Exactly
    }
}

Describe 'Get-RotationCandidate takes the machines it is given' {

    BeforeAll {
        function Get-AzVM { param($Name, $ResourceGroupName, $ErrorAction) }

        $script:LinuxVM = [pscustomobject]@{
            Name              = 'jump-01'
            ResourceGroupName = 'rg-a'
            Id                = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/jump-01'
            Tags              = @{}
            OSProfile         = [pscustomobject]@{
                AdminUsername      = 'azureuser'
                LinuxConfiguration = [pscustomobject]@{ DisablePasswordAuthentication = $true }
            }
            StorageProfile    = [pscustomobject]@{ OsDisk = [pscustomobject]@{ OsType = 'Linux' } }
        }
    }

    BeforeEach {
        # No pending secret, and a live secret nowhere near its expiry date.
        Mock Get-RotationSecret {
            if ($Name -like '*pending*') { return [pscustomobject]@{ Exists = $false; Secret = $null } }
            return [pscustomobject]@{
                Exists = $true
                Secret = [pscustomobject]@{
                    Version = 'v1'
                    Enabled = $true
                    Expires = (Get-Date).ToUniversalTime().AddDays(300)
                    Tags    = @{}
                }
            }
        }
    }

    It 'never searches for machines' {
        # Selecting machines is the orchestrator's job. If this ever calls Get-AzVM, the
        # policy has leaked back into the module.
        Mock Get-AzVM { throw 'the module must not discover machines' }
        { Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM } | Should -Not -Throw
    }

    It 'does not care whether the machine carries any tag' {
        $result = @(Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM)
        $result.Count | Should -BeGreaterThan 0
        $result[0].VM.Name | Should -Be 'jump-01'
    }

    It 'rotates a healthy credential by default, because it was handed one' {
        # 300 days from expiry. Doing nothing would be the wrong answer to a direct request.
        $result = @(Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM)
        $result[0].Reason | Should -Be 'Manual'
    }

    It 'leaves a healthy credential alone with -OnlyIfDue' {
        @(Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM -OnlyIfDue) | Should -BeNullOrEmpty
    }

    It 'reports Expiry, not Manual, when it is genuinely near expiry' {
        Mock Get-RotationSecret {
            if ($Name -like '*pending*') { return [pscustomobject]@{ Exists = $false; Secret = $null } }
            [pscustomobject]@{
                Exists = $true
                Secret = [pscustomobject]@{ Version = 'v1'; Enabled = $true; Expires = (Get-Date).ToUniversalTime().AddDays(3); Tags = @{} }
            }
        }
        $result = @(Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM -OnlyIfDue)
        $result[0].Reason | Should -Be 'Expiry'
    }

    It 'still reports a missing secret as Missing' {
        Mock Get-RotationSecret { [pscustomobject]@{ Exists = $false; Secret = $null } }
        $result = @(Get-RotationCandidate -VaultName 'kv' -VM $script:LinuxVM)
        $result[0].Reason | Should -Be 'Missing'
    }

    It 'ignores a hold tag, because holding is not its decision' {
        $held = $script:LinuxVM.PSObject.Copy()
        $held.Tags = @{ CredentialRotationHold = 'true' }
        # The orchestrator filters these out before calling. The module rotating it anyway
        # is correct: it was handed a machine and told to look at it.
        @(Get-RotationCandidate -VaultName 'kv' -VM $held).Count | Should -BeGreaterThan 0
    }
}

Describe 'The module holds no selection policy' {

    BeforeAll {
        $script:SourceFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'src' 'AzureVMCredentialRotation') -Filter '*.ps1' -Recurse
        $script:RunbookFile = Join-Path $PSScriptRoot '..' 'src' 'runbooks' 'Invoke-CredentialRotationRunbook.ps1'
    }

    It 'never lists machines' {
        # Asked of the parser, not of a regex: the first version of this test failed on the
        # words "Get-AzVM" inside a help block, which is exactly the kind of false alarm
        # that gets a guard deleted.
        #
        # Get-AzVM with -Name or -ResourceGroupName is resolving something the caller
        # asked for. A bare Get-AzVM is a search, and searching is the orchestrator's job.
        $offenders = foreach ($file in $script:SourceFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-AzVM'
                }, $true)

            foreach ($call in $calls) {
                $names = @($call.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
                if (-not ($names -contains 'Name' -or $names -contains 'ResourceGroupName')) { $file.Name }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "these search for machines instead of being given them: $($offenders -join ', ')"
    }

    It 'never reads an enable or hold tag' {
        # Parameter and variable names only. The words may still appear in prose that
        # explains where the policy went.
        $offenders = foreach ($file in $script:SourceFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $vars = $ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)
            if ($vars.VariablePath.UserPath -match '^(EnableTagName|EnableTagValue|HoldTagName)$') { $file.Name }
        }
        $offenders | Should -BeNullOrEmpty -Because "tags are the orchestrator's vocabulary, but these use them: $($offenders -join ', ')"
    }

    It 'and the runbook does both, so the behaviour did not simply disappear' {
        $runbook = Get-Content -Path $script:RunbookFile -Raw
        $runbook | Should -Match 'Get-AzVM'
        $runbook | Should -Match 'EnableTagName'
        $runbook | Should -Match 'HoldTagName'
    }

    It 'and the scheduled pass asks for due credentials only' {
        # The module rotates whatever it is handed. Without this switch a six-hourly job
        # would re-roll every credential in the estate, four times a day, quietly.
        $runbook = Get-Content -Path $script:RunbookFile -Raw
        $runbook | Should -Match 'OnlyIfDue\s*=\s*\$true'
    }
}
