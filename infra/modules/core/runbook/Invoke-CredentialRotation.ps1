<#
    GENERATED FILE - DO NOT EDIT

    Built from src/ by build/Build-Runbook.ps1.
    Edit the module under src/AzureVMCredentialRotation or the wrapper under src/runbooks,
    then rebuild and commit the result.

    Module version: 0.4.1
#>

#Requires -Version 7.2
<#
.SYNOPSIS
    Azure Automation entry point for VM credential rotation.

.DESCRIPTION
    The orchestrator. It authenticates, resolves its configuration, guards against
    overlapping runs, decides which machines are in scope, and hands them to the
    AzureVMCredentialRotation module.

    That split is the point. The module rotates the machines it is given and has no
    opinion about tags; every policy decision - which machines are enabled, which are
    on hold, which subscriptions to walk, how often to look for reads - lives here.
    So the same module runs from a workstation against one named machine and from this
    runbook against a fleet, without a mode switch.

    Scope is opt-in by tag. A discovery loop that treated "no secret exists for this
    VM" as "rotate it" would, on its first run in an established tenant, change the
    local administrator password of every machine it can see.

    It reaches Azure Automation two ways. The Bicep deployment imports the module from
    the PowerShell Gallery and publishes this file as it stands; the Terraform
    deployment publishes the flattened artefact from build/Build-Runbook.ps1, which
    inlines the module ahead of this wrapper. The import below covers the first case
    and stays out of the way in the second.

    Configuration precedence is parameter, then Automation variable, then default.
    That is what makes the optional parts independently deployable: observability sets
    CR_WorkspaceId and the data collection variables, rotation-after-use sets
    CR_AccessRotationEnabled. Deploy neither and the runbook falls back to plain
    expiry-driven rotation.

.PARAMETER VaultName
    The Key Vault holding the credentials. Normally left unset so the job takes it from
    the automation variable CR_VaultName that the deployment writes; pass it to point one
    manual run at a different vault.

.PARAMETER SubscriptionId
    The subscriptions to walk, comma-separated. Unset means the automation variable
    CR_SubscriptionId, and unset there means the subscription the automation account
    itself lives in. Naming subscriptions is what makes a cross-subscription estate work:
    the identity's role assignments still have to reach them.

.PARAMETER ThresholdDays
    How close to expiry counts as due, defaulting to fourteen through CR_ThresholdDays.
    Read together with the schedule: a machine is only seen when a job runs, so the
    threshold has to be comfortably wider than the interval between runs.

.PARAMETER ValidityDays
    How far ahead a new secret's expiry date is set, defaulting to ninety through
    CR_ValidityDays. Since the expiry date is the only signal, this is the rotation
    interval. A STIG-hardened Linux image enforces a shorter maximum password age, so
    match it there rather than letting the guest and the vault disagree.

.PARAMETER EnableTagName
    The VM tag that opts a machine in, defaulting to CredentialRotation through
    CR_EnableTagName. This is the orchestrator's vocabulary and nothing else reads it -
    the module is handed machines, never a tag name.

.PARAMETER EnableTagValue
    The value that tag must carry, defaulting to enabled through CR_EnableTagValue. A
    machine tagged with anything else is out of scope, which is how a fleet is onboarded
    in batches rather than all at once.

.PARAMETER SkipSshKeys
    Rotates passwords only and leaves Linux SSH keys alone. Set it through
    CR_SkipSshKeys where the keys belong to configuration management.

.PARAMETER RemovePriorSshKeys
    Off by default, and worth leaving off: the VMAccess extension can wipe every entry in
    authorized_keys, which takes out colleagues, configuration management and backup
    agents along with the key being replaced.

.PARAMETER ResetSshConfiguration
    Off by default: VMAccess can restore sshd configuration to its default, silently
    undoing hardening on a CIS-baselined host.

.PARAMETER SecretNameTemplate
    How secret names are built, from {vm}, {user}, {rg} and {kind}. Defaults to the shape
    this tool has always used. Set it where two machines could share a name, or where the
    vault already has a convention; it has to stay the same for the life of a secret.

.PARAMETER HoldTagName
    VM tag that takes a machine out of scope for this run without untagging it. Checked
    here rather than in the module, because it is a policy statement about a machine
    rather than a fact about the credential.

.PARAMETER DryRun
    Runs the whole pass under -WhatIf. Use this first, always. Passed explicitly for a
    manual run; the scheduled job leaves it to the automation variable CR_DryRun, which is
    what the deployment's dryRun setting writes. It lives in a variable rather than in the
    job schedule's parameters because Automation ignores a PUT on a schedule link that
    already exists - a redeployment with dryRun=false would report success and change
    nothing.

.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-credrotation -ResourceGroupName rg-credrotation -Name Invoke-CredentialRotationRunbook -Parameters @{ DryRun = $true }

    The first run after a deployment. Reports what it would replace across every tagged
    machine and changes nothing. Read one of these before turning the schedule loose.

.EXAMPLE
    Set-AzAutomationVariable -AutomationAccountName aa-credrotation -ResourceGroupName rg-credrotation -Name CR_DryRun -Value 'false' -Encrypted $false

    How the scheduled job leaves dry-run mode. The schedule carries no parameters on
    purpose: Automation ignores a PUT on a job schedule that already exists, so a
    redeployment with dryRun=false would report success and change nothing.

.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-credrotation -ResourceGroupName rg-credrotation -Name Invoke-CredentialRotationRunbook -Parameters @{ SubscriptionId = '<sub-a>,<sub-b>'; DryRun = $true }

    A cross-subscription pass, forced for one run. Both subscriptions have to be within
    reach of the managed identity's role assignments; naming one it cannot see produces a
    permission error rather than an empty result.

.NOTES
    Requires the automation account's managed identity to hold:
      Key Vault Secrets Officer   on the vault
      Virtual Machine Contributor on the VM scopes
      Log Analytics Reader        on the workspace   (only for access-driven rotation)
      Monitoring Metrics Publisher on the DCR        (only for audit records)
#>
[CmdletBinding()]
param(
    [string]$VaultName,
    [string]$SubscriptionId,

    [int]$ThresholdDays = 0,
    [int]$ValidityDays = 0,

    [string]$EnableTagName,
    [string]$EnableTagValue,

    # A vault with its own convention, or an estate where two machines can share a name -
    # a VM name is unique in a resource group, not in a subscription, so '{rg}-{vm}-{kind}'
    # is what keeps those two apart. Must stay the same for the life of a secret.
    [string]$SecretNameTemplate,

    # Not an automation variable on purpose: adding one would change the deployment
    # contract that Bicep, Terraform and the contract test all agree on, for a name
    # nobody has ever needed to override.
    [string]$HoldTagName = 'CredentialRotationHold',

    [bool]$SkipSshKeys = $false,
    [bool]$RemovePriorSshKeys = $false,
    [bool]$ResetSshConfiguration = $false,

    [bool]$DryRun = $false
)

#region Private

# --- Private/Get-RotationSecret.ps1 ---------------------------------
function Get-RotationSecret {
    <#
    .SYNOPSIS
        Reads secret metadata, distinguishing "does not exist" from "cannot read".

    .DESCRIPTION
        This distinction is the single most important piece of error handling in the
        project. Get-AzKeyVaultSecret returns $null when a secret is absent and
        throws when the call itself fails - a denied role assignment, throttling, a
        firewall, a transient network fault.

        Treating both as "no secret, therefore rotate" is how you end up changing a
        VM password and then failing to store it. This function returns Exists=$false
        only for a genuine absence and rethrows everything else, so a permissions
        problem surfaces as a failure instead of a rotation.

        Note that -IncludeVersions is not used: metadata is enough to decide, and not
        reading the value keeps this call out of the SecretGet audit trail that the
        access-triggered rotation depends on.

        A disabled secret is a third case, and it is not obvious: Key Vault answers a
        read with 403 "Operation get is not allowed on a disabled secret". That looks
        exactly like a permissions failure, so without special handling a single
        disabled secret anywhere in the vault aborts discovery for the whole
        subscription - which is precisely what happened on a live run.

    .OUTPUTS
        PSCustomObject with Exists, Disabled and Secret (the Key Vault secret, or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop

        return [pscustomobject]@{
            Exists   = $null -ne $secret
            Disabled = $false
            Secret   = $secret
        }
    }
    catch {
        # Az surfaces a missing secret as $null, but be explicit in case a future
        # version starts throwing: only a genuine 404 counts as absent.
        $isNotFound = $_.Exception.Message -match 'SecretNotFound' -or
                      $_.Exception.Response.StatusCode -eq 404

        if ($isNotFound) {
            return [pscustomobject]@{ Exists = $false; Disabled = $false; Secret = $null }
        }

        # Disabled: the secret exists but cannot be read. Not a permissions problem,
        # and not a reason to stop.
        if ($_.Exception.Message -match 'disabled secret') {
            return [pscustomobject]@{ Exists = $true; Disabled = $true; Secret = $null }
        }

        throw "Cannot read secret metadata '$Name' from vault '$VaultName'. Refusing to treat this as a missing secret. $($_.Exception.Message)"
    }
}

# --- Private/New-RotationPassword.ps1 -------------------------------
function New-RotationPassword {
    <#
    .SYNOPSIS
        Generates a random password with a uniform character distribution.

    .DESCRIPTION
        Uses rejection sampling instead of a plain modulo over random bytes. A modulo
        maps 256 byte values onto an alphabet that does not divide 256 evenly, which
        makes the first few characters of the alphabet slightly more likely. The bias
        is small, but it is free to avoid and it is the first thing a reader checks.

        Complexity is satisfied by drawing at least one character from each required
        class and shuffling, rather than by inserting known characters at fixed
        positions.

        Excluded from the alphabet: quote, backslash, backtick, dollar and space.
        Those survive badly through ARM templates, JSON payloads and shells, and the
        VMAccess extension passes the value through several of them.

    .OUTPUTS
        System.Security.SecureString
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [ValidateRange(12, 123)]
        [int]$Length = 24
    )

    $classes = @(
        'abcdefghijkmnopqrstuvwxyz'      # no l
        'ABCDEFGHJKLMNPQRSTUVWXYZ'       # no I, no O
        '23456789'                       # no 0, no 1
        '!#%&()*+,-./:;<=>?@[]^_{|}~'
    )
    $alphabet = -join $classes

    $chars = [System.Collections.Generic.List[char]]::new()

    # One character from each class guarantees complexity without a fixed position.
    foreach ($class in $classes) {
        $chars.Add((Get-UniformChar -Alphabet $class))
    }
    while ($chars.Count -lt $Length) {
        $chars.Add((Get-UniformChar -Alphabet $alphabet))
    }

    # Fisher-Yates with a cryptographic source, so the guaranteed characters do not
    # sit at predictable offsets.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $secure = [securestring]::new()
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()

    # Clear the plaintext characters we still hold.
    for ($i = 0; $i -lt $chars.Count; $i++) { $chars[$i] = [char]0 }
    $chars.Clear()

    return $secure
}

function Get-UniformChar {
    <#
    .SYNOPSIS
        Draws a single character from an alphabet without modulo bias.
    #>
    [CmdletBinding()]
    [OutputType([char])]
    param(
        [Parameter(Mandatory)]
        [string]$Alphabet
    )

    return $Alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $Alphabet.Length)]
}

# --- Private/New-RotationRecord.ps1 ---------------------------------
function New-RotationRecord {
    <#
    .SYNOPSIS
        Builds the record shape expected by the CredentialRotation_CL custom table.

    .DESCRIPTION
        TimeGenerated is set explicitly so the record carries the time the rotation
        completed rather than the time the batch happened to flush.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$OSType,
        [Parameter(Mandatory)][ValidateSet('Password', 'SSHKey')][string]$CredentialType,
        [Parameter(Mandatory)][ValidateSet('Expiry', 'Access', 'Missing', 'Manual', 'ResumePending')][string]$TriggerReason,
        [Parameter(Mandatory)][ValidateSet('Rotated', 'Skipped', 'Failed', 'WhatIf')][string]$Result,

        [datetime]$StartedAt = (Get-Date).ToUniversalTime(),
        [string]$TriggeredBy,
        [string]$PreviousSecretVersion,
        [string]$NewSecretVersion,
        [string]$Detail
    )

    $now = (Get-Date).ToUniversalTime()

    return [pscustomobject]@{
        TimeGenerated         = $now.ToString('o')
        SecretName            = $SecretName
        VMName                = $VMName
        ResourceGroupName     = $ResourceGroupName
        SubscriptionId        = $SubscriptionId
        OSType                = $OSType
        CredentialType        = $CredentialType
        TriggerReason         = $TriggerReason
        TriggeredBy           = $TriggeredBy
        Result                = $Result
        StartedAt             = $StartedAt.ToString('o')
        DurationMs            = [int]($now - $StartedAt).TotalMilliseconds
        PreviousSecretVersion = $PreviousSecretVersion
        NewSecretVersion      = $NewSecretVersion
        Detail                = $Detail
    }
}

# --- Private/New-RotationSshKeyPair.ps1 -----------------------------
function New-RotationSshKeyPair {
    <#
    .SYNOPSIS
        Generates an RSA key pair in OpenSSH-compatible form.

    .DESCRIPTION
        Produces a PKCS#8 PEM private key and an "ssh-rsa" public key.

        Two details matter and are easy to get wrong:

        1. PEM line endings. Base64FormattingOptions::InsertLineBreaks emits CRLF.
           Mixing that with LF-terminated header lines produces a file that some
           OpenSSH clients reject outright. This function wraps at 64 characters
           with LF only.

        2. The public key wire format. "ssh-rsa" is a sequence of length-prefixed
           big-endian fields, and each integer needs a leading zero byte when its
           most significant bit is set, or it reads as negative. Building that by
           appending to a PowerShell array happens to work for RSA and silently
           breaks the moment anything changes, so it is written explicitly here.

        RSA rather than Ed25519 because the .NET 6 runtime behind PowerShell 7.2
        runbooks has no Ed25519 primitive. If you run this somewhere with a newer
        runtime, Ed25519 is the better default.

    .OUTPUTS
        PSCustomObject with PrivateKey (SecureString, PEM) and PublicKey (String).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet(2048, 3072, 4096)]
        [int]$KeySize = 4096
    )

    $rsa = [System.Security.Cryptography.RSA]::Create($KeySize)
    try {
        $pem = ConvertTo-PemBlock -Der $rsa.ExportPkcs8PrivateKey() -Label 'PRIVATE KEY'

        $parameters = $rsa.ExportParameters($false)
        $publicKey = ConvertTo-OpenSshPublicKey -Exponent $parameters.Exponent -Modulus $parameters.Modulus

        return [pscustomobject]@{
            PrivateKey = ConvertTo-SecureString -String $pem -AsPlainText -Force
            PublicKey  = $publicKey
        }
    }
    finally {
        $rsa.Dispose()
        $pem = $null
        $parameters = $null
    }
}

function ConvertFrom-PemToSshPublicKey {
    <#
    .SYNOPSIS
        Derives the "ssh-rsa" public key from a PKCS#8 private key PEM.

    .DESCRIPTION
        Used when resuming an interrupted rotation. The staged secret holds only the
        private key, so the public key has to be recomputed rather than stored
        alongside it - a 4096-bit ssh-rsa key is roughly 700 characters and Key Vault
        caps a tag value at 256, so keeping it as a tag silently worked in testing and
        failed against a real vault with "Property has invalid value".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][securestring]$PrivateKeyPem
    )

    $pem = ConvertFrom-SecureString -SecureString $PrivateKeyPem -AsPlainText
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($pem)
        $parameters = $rsa.ExportParameters($false)
        return ConvertTo-OpenSshPublicKey -Exponent $parameters.Exponent -Modulus $parameters.Modulus
    }
    finally {
        $rsa.Dispose()
        $pem = $null
        [System.GC]::Collect()
    }
}

function ConvertTo-PemBlock {
    <#
    .SYNOPSIS
        Wraps DER bytes in a PEM block with LF line endings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]]$Der,
        [Parameter(Mandatory)][string]$Label
    )

    $base64 = [Convert]::ToBase64String($Der)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("-----BEGIN $Label-----`n")
    for ($i = 0; $i -lt $base64.Length; $i += 64) {
        $take = [Math]::Min(64, $base64.Length - $i)
        [void]$builder.Append($base64.Substring($i, $take)).Append("`n")
    }
    [void]$builder.Append("-----END $Label-----`n")

    return $builder.ToString()
}

function ConvertTo-OpenSshPublicKey {
    <#
    .SYNOPSIS
        Encodes RSA public parameters as an "ssh-rsa" public key string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]]$Exponent,
        [Parameter(Mandatory)][byte[]]$Modulus
    )

    $stream = [System.IO.MemoryStream]::new()
    try {
        Write-SshString -Stream $stream -Value ([System.Text.Encoding]::ASCII.GetBytes('ssh-rsa'))
        Write-SshMpint -Stream $stream -Value $Exponent
        Write-SshMpint -Stream $stream -Value $Modulus

        return 'ssh-rsa ' + [Convert]::ToBase64String($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

function Write-SshString {
    <#
    .SYNOPSIS
        Writes a length-prefixed byte string in SSH wire format (RFC 4251).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][byte[]]$Value
    )

    $length = [BitConverter]::GetBytes([uint32]$Value.Length)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($length) }

    $Stream.Write($length, 0, 4)
    $Stream.Write($Value, 0, $Value.Length)
}

function Write-SshMpint {
    <#
    .SYNOPSIS
        Writes a multiple-precision integer in SSH wire format (RFC 4251).

    .DESCRIPTION
        mpint values are two's complement. A leading zero byte is required when the
        most significant bit is set, otherwise the value reads as negative. An RSA
        modulus always has that bit set; a public exponent of 65537 does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][byte[]]$Value
    )

    # Strip any leading zero bytes the provider may have included.
    $offset = 0
    while ($offset -lt ($Value.Length - 1) -and $Value[$offset] -eq 0) { $offset++ }
    $trimmed = $Value[$offset..($Value.Length - 1)]

    if ($trimmed[0] -band 0x80) {
        $padded = [byte[]]::new($trimmed.Length + 1)
        $padded[0] = 0
        [Array]::Copy($trimmed, 0, $padded, 1, $trimmed.Length)
        $trimmed = $padded
    }

    Write-SshString -Stream $Stream -Value $trimmed
}

# --- Private/Resolve-SecretName.ps1 ---------------------------------
function Resolve-SecretName {
    <#
    .SYNOPSIS
        Builds the Key Vault secret name for a VM credential.

    .DESCRIPTION
        Key Vault secret names allow only alphanumerics and dashes, and are limited
        to 127 characters. VM names and admin usernames can contain neither of those
        guarantees, so both are normalised and the result is truncated with a short
        hash suffix when it would otherwise overflow.

    .PARAMETER Kind
        pw       - password, Windows or Linux
        ssh-priv - SSH private key, Linux
        ssh-pub  - SSH public key, Linux
        pending  - staged value written before the VM is updated, see Update-VMCredential

    .PARAMETER ResourceGroupName
        Fills {rg}. Required only when the template uses it.

    .PARAMETER Template
        How the name is built, with {vm}, {user}, {rg} and {kind} as placeholders. The
        default is the shape this tool has always used. It has to contain {vm} and {kind}:
        without the first every machine lands on the same secret, without the second a
        password and an SSH key do. {user} is optional, for vaults that already key by
        machine.

        {rg} exists because a VM name is not unique in a subscription. Two machines called
        web-01 in different resource groups resolve to one secret under the default
        template, and the vault then holds a credential that works on one of them with
        nothing saying which - see KNOWN-ISSUES. Where that can happen, key the name by
        resource group as well: '{rg}-{vm}-{kind}'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][ValidateSet('pw', 'ssh-priv', 'ssh-pub')][string]$Kind,
        [string]$ResourceGroupName,
        [switch]$Pending,
        [ValidateNotNullOrEmpty()][string]$Template = '{vm}-{user}-{kind}'
    )

    foreach ($required in '{vm}', '{kind}') {
        if ($Template -notlike "*$required*") {
            throw "Secret name template '$Template' must contain $required, otherwise different credentials collide on one secret."
        }
    }

    # Silently dropping {rg} would produce a name that looks deliberate and collides anyway.
    if ($Template -like '*{rg}*' -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "Secret name template '$Template' uses {rg}, but no resource group name was supplied."
    }

    $normalise = {
        param($value)
        ($value -replace '[^a-zA-Z0-9-]', '-') -replace '-+', '-'
    }

    # {rg} is lower-cased, the others are not. A subscription-wide Get-AzVM returns the resource
    # group name upper-cased while a targeted one returns it as typed, so the same machine would
    # otherwise produce a differently-cased name depending on how the caller found it. Key Vault
    # looks names up case-insensitively, so this is about a stable name rather than a second
    # secret - but a name that changes shape between the runbook and a prompt is its own problem.
    $name = $Template.
        Replace('{vm}', (& $normalise $VMName)).
        Replace('{user}', (& $normalise $AdminUsername)).
        Replace('{rg}', (& $normalise ([string]$ResourceGroupName)).ToLowerInvariant()).
        Replace('{kind}', $Kind)
    # Literal characters in the template get the same treatment as the values.
    $name = (& $normalise $name)
    if ($Pending) { $name += '-pending' }
    $name = $name.Trim('-')

    if ($name.Length -gt 127) {
        # Keep the name recognisable and unique: truncate and append a short digest
        # of the full name.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name))
            $suffix = ([Convert]::ToHexString($hash)).Substring(0, 8).ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
        $name = $name.Substring(0, 118) + '-' + $suffix
    }

    return $name
}

# --- Private/Resolve-TargetVM.ps1 -----------------------------------
function Resolve-TargetVM {
    <#
    .SYNOPSIS
        Turns a VM name into the full VM object the rotation needs.

    .DESCRIPTION
        Two traps here, both of which produce a misleading error much later if they are
        not handled where the name is resolved.

        The first is ambiguity. `Get-AzVM -Name` searches the whole subscription, and a
        name like "jump-01" is entirely capable of existing in three resource groups.
        Picking the first one would rotate a credential on a machine the caller did not
        mean. So an ambiguous name is an error that names the candidates, not a guess.

        The second is that the list form of Get-AzVM returns a partial object: no
        OSProfile, so no AdminUsername. Everything downstream reads AdminUsername, and
        its absence is the documented symptom of a specialised image - so a machine
        found by name alone would be reported as unsupported rather than as found. The
        resolved name is therefore always fetched again in the single-VM form, which
        populates the whole object.

    .PARAMETER Name
        The VM name to find.

    .PARAMETER ResourceGroupName
        Narrows the search. Without it the whole subscription is searched.

    .OUTPUTS
        The VM object, with its OS profile populated.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ResourceGroupName
    )

    if ($ResourceGroupName) {
        # Already unambiguous, and this form returns the full object.
        return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    }

    $found = @(Get-AzVM -Name $Name -ErrorAction Stop)

    if ($found.Count -eq 0) {
        throw "No VM named '$Name' in this subscription. Check the name, or the subscription your context is pointing at."
    }

    if ($found.Count -gt 1) {
        $groups = ($found | ForEach-Object { $_.ResourceGroupName } | Sort-Object -Unique) -join ', '
        throw "'$Name' exists in more than one resource group ($groups). Pass -ResourceGroupName to say which one."
    }

    # Fetched again on purpose: the list form above has no OSProfile.
    return Get-AzVM -ResourceGroupName $found[0].ResourceGroupName -Name $found[0].Name -ErrorAction Stop
}

# --- Private/Test-VMRunning.ps1 -------------------------------------
function Test-VMRunning {
    <#
    .SYNOPSIS
        Returns whether a VM is running.

    .DESCRIPTION
        The VMAccess extension needs a running VM and a healthy guest agent. Rotating
        against a stopped VM either fails or, worse, appears to succeed while the
        guest never applies the change - which would leave Key Vault and the machine
        holding different passwords.

        A stopped VM is not an error. It is skipped, and the next scheduled run picks
        it up. That is the whole retry mechanism.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )

    $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status -ErrorAction Stop

    $powerState = $status.Statuses |
        Where-Object { $_.Code -like 'PowerState/*' } |
        Select-Object -First 1 -ExpandProperty Code

    return $powerState -eq 'PowerState/running'
}

# --- Private/Write-RotationLog.ps1 ----------------------------------
function Write-RotationLog {
    <#
    .SYNOPSIS
        Writes a structured line to the job log.

    .DESCRIPTION
        Uses Write-Verbose with an explicit -Verbose, which is the only option that is
        both visible in Azure Automation and safe inside a function that returns a
        value. Measured against a real automation account, PowerShell 7.2 runbook:

            Write-Output        visible, but writes to the success stream, so every
                                log line becomes part of the calling function's return
                                value - our own tests caught exactly that
            Write-Host          never appears in the job streams at all
            Write-Information   never appears either, with or without
                                -InformationAction Continue
            Write-Verbose       appears as a Verbose stream, leaves the pipeline alone
            Write-Warning       appears, but everything would be a warning

        The catch: Automation drops the verbose stream entirely unless the runbook has
        logVerbose enabled, which is why the core Terraform module defaults it to true.
        The runbook wrapper sets $VerbosePreference to SilentlyContinue first, so the
        Az module import chatter - several hundred lines per job - stays out, while
        these explicit calls still come through.

        The run summary additionally goes to the output stream, so the headline numbers
        survive even if someone turns verbose logging off.

        Never pass credential material into this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info',

        [string]$Scope
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $prefix = if ($Scope) { "[$Level] [$Scope]" } else { "[$Level]" }

    # -Verbose explicitly: the wrapper silences $VerbosePreference to keep the Az
    # module import chatter out of the job, and these lines have to survive that.
    Write-Verbose "$timestamp $prefix $Message" -Verbose

    # Warnings and errors also go to their own streams, which Automation surfaces
    # regardless of the verbose setting - so a failing job is legible even with
    # verbose logging turned off.
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error -Message $Message -ErrorAction Continue }
    }
}

#endregion Private

#region Public

# --- Public/Get-RotationCandidate.ps1 -------------------------------
function Get-RotationCandidate {
    <#
    .SYNOPSIS
        Works out which credentials on the given machines need rotating.

    .DESCRIPTION
        The caller states the machines. This function never searches for them, never
        reads a tag and has no opinion about which machines belong in scope - that is
        the orchestrator's job, and keeping it there is what lets the same module run
        from a workstation against one machine and from a runbook against a fleet.

        What it does decide is whether a machine the caller already chose actually has
        something to rotate. Rotation is triggered by one of five conditions:

          ResumePending - a previous run was interrupted after staging a value
          Missing       - no secret yet, or a secret with no expiry date
          Expiry        - the expiry date is within the threshold
          Access        - not detected here; access pulls the expiry date forward,
                          and this function then sees it as Expiry
          Manual        - nothing else applied, so the credential is replaced because
                          the caller asked for this machine

        Access is the one worth reading twice, because it is the design in one sentence:
        the expiry date is the only signal, and everything else writes to it.

    .PARAMETER VaultName
        The Key Vault holding the credentials. Only read here: this function decides what
        is due, it never writes.

    .PARAMETER VM
        The machines to examine. Objects from Get-AzVM, fetched by the caller.

    .PARAMETER OnlyIfDue
        Consult the expiry date instead of rotating regardless. Without it every machine
        handed in is a candidate, which is what asking for a machine means. A scheduled
        pass sets it, so it touches only what is missing, half-rotated or near expiry.

    .PARAMETER ThresholdDays
        How close to expiry counts as due. Only consulted with -OnlyIfDue.

    .PARAMETER SkipSshKeys
        Leaves SSH keys out of the answer. Without it a Linux machine yields a key
        candidate as well as a password one.

    .PARAMETER SecretNameTemplate
        How secret names are built from {vm}, {user}, {rg} and {kind}. Must match what was
        used when the secrets were written, or nothing will be found.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM (Get-AzVM -ResourceGroupName rg-dmz)

        Every credential on every machine in that resource group, because asking for a
        machine is itself the reason to rotate it. Reason comes back as Manual.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue -ThresholdDays 14

        What a scheduled pass asks: only what is missing, half-rotated or within
        fourteen days of expiry. Reason distinguishes Missing, Expiry and ResumePending.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue |
            Format-Table VM, CredentialType, Reason, ExpiresOn

        Dry inspection before a first run over an estate. Nothing is changed by asking,
        so this is the cheapest way to see how much work the next rotation would be.

    .OUTPUTS
        PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$VM,

        [switch]$OnlyIfDue,

        # Only consulted with -OnlyIfDue.
        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        # Linux VMs get an SSH key rotated unless this is set.
        [switch]$SkipSshKeys,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}'
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $now = (Get-Date).ToUniversalTime()

    $vms = @($VM)
    Write-RotationLog -Message "$($vms.Count) machine(s) handed in by the caller" -Level Info -Scope 'discovery'

    foreach ($vm in $vms) {
        $adminUsername = $vm.OSProfile.AdminUsername
        if ([string]::IsNullOrWhiteSpace($adminUsername)) {
            Write-RotationLog -Message 'No admin username in the OS profile (specialised image?), skipping' -Level Warning -Scope $vm.Name
            continue
        }

        $osType = [string]$vm.StorageProfile.OsDisk.OsType
        $types = [System.Collections.Generic.List[string]]::new()

        if ($osType -eq 'Windows') {
            $types.Add('Password')
        }
        elseif ($osType -eq 'Linux') {
            $passwordAuthEnabled = -not $vm.OSProfile.LinuxConfiguration.DisablePasswordAuthentication
            if ($passwordAuthEnabled) { $types.Add('Password') }
            if (-not $SkipSshKeys) { $types.Add('SSHKey') }
        }
        else {
            Write-RotationLog -Message "Unknown OS type '$osType', skipping" -Level Warning -Scope $vm.Name
            continue
        }

        foreach ($type in $types) {
            $kind = if ($type -eq 'Password') { 'pw' } else { 'ssh-priv' }
            $secretName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $vm.ResourceGroupName -Template $SecretNameTemplate
            $pendingName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $vm.ResourceGroupName -Pending -Template $SecretNameTemplate

            $reason = $null
            $expiresOn = $null

            $pending = Get-RotationSecret -VaultName $VaultName -Name $pendingName
            $isPendingOpen = $pending.Exists -and
                             $pending.Secret.Tags.State -eq 'pending' -and
                             $pending.Secret.Enabled -ne $false

            if ($isPendingOpen) {
                $reason = 'ResumePending'
            }
            else {
                $secret = Get-RotationSecret -VaultName $VaultName -Name $secretName

                if (-not $secret.Exists) {
                    $reason = 'Missing'
                }
                elseif ($null -eq $secret.Secret.Expires) {
                    $reason = 'Missing'
                    Write-RotationLog -Message "Secret '$secretName' has no expiry date" -Level Warning -Scope $vm.Name
                }
                elseif (-not $OnlyIfDue) {
                    # The caller handed this machine over. Doing nothing because the date is
                    # comfortable would be the wrong answer to a direct request.
                    $expiresOn = $secret.Secret.Expires.ToUniversalTime()
                    $reason = 'Manual'
                }
                else {
                    $expiresOn = $secret.Secret.Expires.ToUniversalTime()
                    if (($expiresOn - $now).TotalDays -le $ThresholdDays) {
                        # Access-driven rotation works by pulling the expiry date
                        # forward, so by the time it gets here it is indistinguishable
                        # from ordinary ageing. Register-CredentialAccess leaves a tag
                        # behind precisely so the audit record can still say which of
                        # the two it was - without it, the workbook cannot answer
                        # "was this replaced because someone read it, or because it
                        # got old", which is most of the point of keeping records.
                        $reason = if ($secret.Secret.Tags -and $secret.Secret.Tags['RotationReason'] -eq 'Access') {
                            'Access'
                        }
                        else { 'Expiry' }
                    }
                }
            }

            if (-not $reason) { continue }

            $candidates.Add([pscustomobject]@{
                VM             = $vm
                CredentialType = $type
                Reason         = $reason
                SecretName     = $secretName
                ExpiresOn      = $expiresOn
            })
        }
    }

    return $candidates.ToArray()
}

# --- Public/Invoke-CredentialRotation.ps1 ---------------------------
function Invoke-CredentialRotation {
    <#
    .SYNOPSIS
        Rotates the credentials that are due on the machines you give it.

    .DESCRIPTION
        The caller states the machines. This function does not search for them, does not
        read a tag, and has no opinion about which machines belong in scope. That belongs
        to whatever is orchestrating - a runbook, a pipeline, or you at a prompt - and
        keeping it out of here is what lets the same code run against one machine from a
        workstation and against a fleet on a schedule.

        Every machine handed in is rotated. Add -OnlyIfDue and the expiry date gets a vote
        instead, which is what a scheduled pass wants. Whether you passed one name or two
        hundred objects has nothing to do with it.

        Rotation after use is not handled here either. Register-CredentialAccess pulls the
        expiry date of a credential somebody read forward; this function then sees it as
        ordinary ageing. One signal, one code path - and the orchestrator decides how often
        to look.

    .PARAMETER VaultName
        The Key Vault the credentials live in. The one thing this function must be told
        that it cannot work out from the machines themselves.

    .PARAMETER VMName
        Rotate this machine. A convenience over -VM for the common case of one name; it
        behaves identically otherwise.

    .PARAMETER ResourceGroupName
        Narrows -VMName when the same name exists more than once in the subscription.
        Without it, an ambiguous name is an error rather than a guess.

    .PARAMETER VM
        Machines to process, as objects from Get-AzVM. What an orchestrator passes after
        it has selected them.

    .PARAMETER OnlyIfDue
        Rotate only what is missing, half-rotated or near expiry, instead of rotating
        everything handed in. How you name the machines says nothing about this - a
        scheduled pass sets it, a person at a prompt usually does not.

    .PARAMETER ThresholdDays
        How close to expiry counts as due. Only consulted with -OnlyIfDue.

    .PARAMETER ValidityDays
        How far ahead each new secret's expiry date is set. Since the expiry date is the
        only signal, this is the rotation interval: ninety days here means a credential
        comes back around in ninety days.

    .PARAMETER SkipSshKeys
        Rotates passwords only, leaving Linux SSH keys alone. Useful while onboarding an
        estate where the keys are managed by something else.

    .PARAMETER RemovePriorSshKeys
        Passed through to Update-VMCredential, and off by default for the reason given
        there: VMAccess can wipe every entry in authorized_keys, colleagues and agents
        included.

    .PARAMETER ResetSshConfiguration
        Passed through to Update-VMCredential, and off by default: VMAccess can restore
        sshd configuration to its default and undo hardening on a baselined host.

    .PARAMETER TriggeredBy
        Who or what asked for this run - a runbook job id, a person, a change ticket.
        Recorded on every record the run produces, and never interpreted.

    .PARAMETER SecretNameTemplate
        How secret names are built from {vm}, {user}, {rg} and {kind}. Change it to fit a
        vault that already has a naming convention; keep it the same for the life of a
        secret. Use {rg} where two machines could share a name - a VM name is not unique in
        a subscription, and the default template would put both on one secret.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01 -WhatIf

        Shows what would happen to one machine, from your own workstation, without
        deploying anything. Always the first thing to run.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01

        Rotates that machine now. The secret is created in the vault if it does not
        exist yet, so this is also how a machine is onboarded by hand.

    .EXAMPLE
        $vms = Get-AzVM | Where-Object { $_.Tags.CredentialRotation -eq 'enabled' }
        Invoke-CredentialRotation -VaultName kv-creds -VM $vms -OnlyIfDue

        What an orchestrator does: select the machines however you like, hand them over,
        and ask for only the ones that are due. The tag here is the caller's policy, not
        the module's.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VM $vms

        The same machines, all rotated, due or not. Naming machines and deciding whether
        the expiry date gets a vote are two separate questions, so they are two separate
        parameters.

    .OUTPUTS
        PSCustomObject summarising the run. Records holds one entry per credential touched,
        in the shape CredentialRotation_CL expects, for whoever wants to ship them.
    #>
    # -WhatIf is supported and propagated, but the decision is made where the change is:
    # Update-VMCredential calls ShouldProcess per credential. Confirming once up here
    # instead would collapse a dry run into a single line and throw away the per-credential
    # WhatIf records, which are the reason anybody runs one.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Named')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory, ParameterSetName = 'Named')]
        [ValidateNotNullOrEmpty()][string]$VMName,

        [Parameter(ParameterSetName = 'Named')][string]$ResourceGroupName,

        [Parameter(Mandatory, ParameterSetName = 'Machines')]
        [ValidateNotNullOrEmpty()][object[]]$VM,

        [switch]$OnlyIfDue,

        # Only consulted with -OnlyIfDue.
        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,

        [switch]$SkipSshKeys,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}',

        [string]$TriggeredBy
    )

    $startTime = Get-Date
    # Only ever decides where the machines come from, never what happens to them.
    $named = $PSCmdlet.ParameterSetName -eq 'Named'
    $records = [System.Collections.Generic.List[object]]::new()

    $stats = [ordered]@{
        Candidates = 0
        Rotated    = 0
        Skipped    = 0
        Failed     = 0
    }

    Write-RotationLog -Message '=== Credential rotation started ===' -Level Info

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Connect with Connect-AzAccount (or -Identity in Automation) first.'
    }

    # --- the machines --------------------------------------------------------
    # Named or handed in, but always stated by the caller. Nothing here searches.
    $machines = if ($named) {
        @(Resolve-TargetVM -Name $VMName -ResourceGroupName $ResourceGroupName)
    }
    else {
        @($VM)
    }

    $scope = if ($OnlyIfDue) { "only what is due within $ThresholdDays d" } else { 'everything handed in' }
    Write-RotationLog -Message "Vault: $VaultName | machines: $($machines.Count) | $scope | validity: $ValidityDays d" -Level Info

    # A threshold with nothing to apply to is the kind of parameter that looks like it
    # worked. Say so rather than ignoring it quietly.
    if ($PSBoundParameters.ContainsKey('ThresholdDays') -and -not $OnlyIfDue) {
        Write-RotationLog -Message '-ThresholdDays was given without -OnlyIfDue, so it has no effect: every machine handed in is being rotated.' -Level Warning
    }

    # --- what to rotate ------------------------------------------------------
    try {
        $candidates = Get-RotationCandidate -VaultName $VaultName -VM $machines `
            -OnlyIfDue:$OnlyIfDue -ThresholdDays $ThresholdDays -SkipSshKeys:$SkipSshKeys `
            -SecretNameTemplate $SecretNameTemplate
    }
    catch {
        Write-RotationLog -Message "Could not work out what is due: $($_.Exception.Message)" -Level Error
        throw
    }

    $stats.Candidates = @($candidates).Count
    Write-RotationLog -Message "$(@($candidates).Count) credential(s) to process" -Level Info

    # --- rotate --------------------------------------------------------------
    foreach ($candidate in $candidates) {
        try {
            $record = Update-VMCredential -VaultName $VaultName -VM $candidate.VM `
                -CredentialType $candidate.CredentialType -ValidityDays $ValidityDays `
                -TriggerReason $candidate.Reason -TriggeredBy $TriggeredBy `
                -RemovePriorSshKeys:$RemovePriorSshKeys `
                -ResetSshConfiguration:$ResetSshConfiguration `
                -SecretNameTemplate $SecretNameTemplate `
                -WhatIf:$WhatIfPreference -Confirm:$false

            $records.Add($record)

            switch ($record.Result) {
                'Rotated' { $stats.Rotated++ }
                'Skipped' { $stats.Skipped++ }
                'Failed' { $stats.Failed++ }
                'WhatIf' { $stats.Skipped++ }
            }
        }
        catch {
            Write-RotationLog -Message "Unhandled error on $($candidate.VM.Name) ($($candidate.CredentialType)): $($_.Exception.Message)" -Level Error -Scope $candidate.VM.Name
            $stats.Failed++
        }
    }

    $duration = (Get-Date) - $startTime

    Write-RotationLog -Message '=== Summary ===' -Level Info
    Write-RotationLog -Message "Duration: $($duration.ToString('hh\:mm\:ss'))" -Level Info
    Write-RotationLog -Message "Candidates: $($stats.Candidates) | rotated: $($stats.Rotated) | skipped: $($stats.Skipped) | failed: $($stats.Failed)" `
        -Level $(if ($stats.Failed -gt 0) { 'Warning' } else { 'Success' })

    return [pscustomobject]@{
        StartedAt  = $startTime.ToUniversalTime()
        Duration   = $duration
        Candidates = $stats.Candidates
        Rotated    = $stats.Rotated
        Skipped    = $stats.Skipped
        Failed     = $stats.Failed
        Records    = $records.ToArray()
    }
}

# --- Public/Register-CredentialAccess.ps1 ---------------------------
function Register-CredentialAccess {
    <#
    .SYNOPSIS
        Brings the expiry date forward for secrets a human has read.

    .DESCRIPTION
        Rotation after use, without a second execution path.

        A credential that someone has read is spent. It has been in a clipboard, a
        terminal scrollback, an RDP client, possibly a screen share or a ticket. The
        useful response is to replace it soon - but not instantly, because the person
        who read it is usually still using it.

        Rather than schedule a delayed job, this writes the deadline where the system
        already looks: the secret's expiry date. Set it to now plus the grace period,
        and the next scheduled run treats it as any other near-expiry secret. No
        timer, no queue, no second code path to test.

        Who read what is the caller's finding, not this function's. It takes a secret
        name and a reader and acts; the orchestrator gets those from the Key Vault
        audit log in Log Analytics (queries/accessed-secrets.kql) and pipes them in.
        That keeps the module free of any workspace dependency, and lets a different
        orchestrator learn about reads however it likes.

        Changing an expiry date is an attribute update. It does not create a new
        secret version and it does not read the value, so it neither disturbs
        consumers nor pollutes the audit trail this function depends on.

    .PARAMETER VaultName
        The vault holding the secret. Only its expiry date is touched; the value is
        never read, which is what keeps this function out of its own audit trail.

    .PARAMETER SecretName
        The secret that was read. Accepts pipeline input by property name, so the
        result of the audit-log query pipes straight in.

    .PARAMETER AccessedBy
        Who read it. Recorded on the secret so the audit trail can say.

    .PARAMETER AccessedAt
        When. Defaults to now; the query supplies LastAccessedAt, which is accepted.

    .PARAMETER GracePeriodHours
        How long the reader keeps working credentials. Eight hours covers a working
        day. Note that a password change does not end an established RDP session, but
        it does break reconnects, UAC elevation and anything that re-authenticates.

    .EXAMPLE
        Register-CredentialAccess -VaultName kv -SecretName vm01-azureuser-pw -AccessedBy alice@contoso.com

        One read, handled by hand. The expiry date moves to now plus the grace period
        and the next scheduled run replaces the credential as ordinary ageing.

    .EXAMPLE
        $reads | Register-CredentialAccess -VaultName kv -GracePeriodHours 8 -WhatIf

        Whatever produced $reads - the KQL in queries/, a SIEM export, a ticket - as
        long as each object carries SecretName and AccessedBy.

    .OUTPUTS
        PSCustomObject per secret, saying whether its expiry was moved.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][string]$SecretName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][string]$AccessedBy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('LastAccessedAt')]
        [datetime]$AccessedAt = (Get-Date).ToUniversalTime(),

        [ValidateRange(0, 168)][int]$GracePeriodHours = 8
    )

    begin {
        $deadline = (Get-Date).ToUniversalTime().AddHours($GracePeriodHours)
    }

    process {
        $outcome = [pscustomobject]@{
            SecretName = $SecretName
            AccessedBy = $AccessedBy
            NewExpiry  = $deadline
            Applied    = $false
        }

        # Staging secrets are read by this tool itself during recovery; never treat
        # them as user access.
        if ($SecretName -like '*-pending') { return }

        $meta = Get-RotationSecret -VaultName $VaultName -Name $SecretName
        if (-not $meta.Exists) {
            Write-RotationLog -Message "'$SecretName' was read but does not exist in the vault, nothing to move" -Level Info -Scope 'access'
            return
        }

        $currentExpiry = if ($meta.Secret.Expires) { $meta.Secret.Expires.ToUniversalTime() } else { $null }

        # Never push an expiry date further out than it already is.
        if ($currentExpiry -and $currentExpiry -le $deadline) {
            Write-RotationLog -Message "'$SecretName' already expires at $($currentExpiry.ToString('u')), no change" -Level Info -Scope 'access'
            return $outcome
        }

        if (-not $PSCmdlet.ShouldProcess($SecretName, "Bring expiry forward to $($deadline.ToString('u'))")) {
            return $outcome
        }

        $tags = @{}
        if ($meta.Secret.Tags) { $meta.Secret.Tags.GetEnumerator() | ForEach-Object { $tags[$_.Key] = $_.Value } }
        $tags['LastAccessedBy'] = $AccessedBy
        $tags['LastAccessedAt'] = $AccessedAt.ToUniversalTime().ToString('o')
        $tags['RotationReason'] = 'Access'

        $null = Update-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName `
            -Expires $deadline -Tag $tags -ErrorAction Stop

        Write-RotationLog -Message "'$SecretName' was read by $AccessedBy, expiry moved to $($deadline.ToString('u'))" -Level Success -Scope 'access'

        $outcome.Applied = $true
        return $outcome
    }
}

# --- Public/Update-VMCredential.ps1 ---------------------------------
function Update-VMCredential {
    <#
    .SYNOPSIS
        Rotates one credential on one VM and stores it in Key Vault.

    .DESCRIPTION
        Write order is the point of this function.

        The naive order is: change the VM, then store the new value. If the Key Vault
        write then fails - throttling, a role assignment that expired, a firewall
        rule - the machine has a password nobody knows. That is unrecoverable without
        a serial console or a disk swap.

        This function stages the value first, in a separate secret named
        "<name>-pending":

            1. write the new value to <name>-pending, tagged State=pending
            2. apply it to the VM through the VMAccess extension
            3. write it to <name> with the real expiry
            4. overwrite <name>-pending with a placeholder, tagged State=consumed

        Any crash leaves the value recoverable. If the run dies between 2 and 3, the
        next run finds an open pending secret, reapplies the same value to the VM
        (idempotent) and promotes it. Callers see <name> only ever holding a value
        the VM has actually accepted.

        The staging secret is overwritten rather than deleted or disabled - see
        Close-PendingCredential for why both of those fail against a real vault.

    .PARAMETER VaultName
        The Key Vault the new value is written to. Written before the machine is touched,
        which is the whole point of the order above.

    .PARAMETER VM
        The machine to change, as an object from Get-AzVM. One machine, not a list: the
        fan-out belongs to Invoke-CredentialRotation.

    .PARAMETER CredentialType
        Password for the local administrator account, or SSHKey for a new key pair on a
        Linux machine. One credential per call, so a machine with both is two calls.

    .PARAMETER ValidityDays
        How far ahead the new secret's expiry date is set. That date is the only thing
        that brings the credential back for rotation, so it is the rotation interval in
        everything but name. Note that a STIG-hardened Linux image enforces a shorter
        maximum password age than the ninety-day default.

    .PARAMETER TriggerReason
        Why this rotation is happening, recorded on the run. Get-RotationCandidate works
        it out; pass it through rather than inventing one, or the audit trail stops
        matching what actually drove the change.

    .PARAMETER TriggeredBy
        Who or what asked for it - a runbook job id, a person, a change ticket. Free text,
        recorded verbatim, never interpreted.

    .PARAMETER SecretNameTemplate
        How the secret name is built from {vm}, {user}, {rg} and {kind}. Must match what
        was used when the secret was written, or this call stages a new secret beside the
        real one instead of replacing it.

    .PARAMETER RemovePriorSshKeys
        Defaults to false, deliberately. The VMAccess extension can wipe every entry
        in authorized_keys, which takes out colleagues, configuration management and
        backup agents along with the key you meant to replace. Turn it on only if you
        are certain this tool owns every key on the machine.

    .PARAMETER ResetSshConfiguration
        Defaults to false, deliberately. VMAccess can restore sshd configuration to
        its default, which silently undoes hardening on a CIS-baselined host.

    .EXAMPLE
        $vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
        Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -WhatIf

        What one rotation would do, without doing it. ShouldProcess is asked per
        credential, so a dry run over a fleet still reports every machine separately.

    .EXAMPLE
        $vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
        Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -Confirm:$false

        Replaces the local administrator password now and stores it with the default
        ninety-day expiry. ConfirmImpact is High, so without -Confirm:$false this prompts.

    .EXAMPLE
        Update-VMCredential -VaultName kv-creds -VM $linuxVm -CredentialType SSHKey -TriggerReason Access -TriggeredBy 'runbook:8f2c' -Confirm:$false

        A key replaced because somebody read the old one. The reason and the caller are
        recorded on the run; they change nothing about how the rotation is performed.

    .OUTPUTS
        PSCustomObject describing the outcome.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][ValidateNotNull()]$VM,
        [Parameter(Mandatory)][ValidateSet('Password', 'SSHKey')][string]$CredentialType,

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,
        [ValidateSet('Expiry', 'Access', 'Missing', 'Manual', 'ResumePending')][string]$TriggerReason = 'Expiry',
        [string]$TriggeredBy,

        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}'
    )

    $startedAt = (Get-Date).ToUniversalTime()
    $adminUsername = $VM.OSProfile.AdminUsername
    $osType = [string]$VM.StorageProfile.OsDisk.OsType
    $subscriptionId = ($VM.Id -split '/')[2]

    if ([string]::IsNullOrWhiteSpace($adminUsername)) {
        throw "VM '$($VM.Name)' has no admin username in its OS profile. This happens with specialised images; such VMs must be excluded from rotation."
    }

    $kind = if ($CredentialType -eq 'Password') { 'pw' } else { 'ssh-priv' }
    $secretName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $VM.ResourceGroupName -Template $SecretNameTemplate
    $pendingName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $VM.ResourceGroupName -Pending -Template $SecretNameTemplate

    $record = @{
        SecretName        = $secretName
        VMName            = $VM.Name
        ResourceGroupName = $VM.ResourceGroupName
        SubscriptionId    = $subscriptionId
        OSType            = $osType
        CredentialType    = $CredentialType
        TriggerReason     = $TriggerReason
        TriggeredBy       = $TriggeredBy
        StartedAt         = $startedAt
    }

    $current = Get-RotationSecret -VaultName $VaultName -Name $secretName
    $previousVersion = if ($current.Exists) { $current.Secret.Version } else { $null }

    if (-not $PSCmdlet.ShouldProcess("$($VM.Name) ($CredentialType)", 'Rotate credential')) {
        Write-RotationLog -Message "Would rotate $CredentialType for $($VM.Name) [$TriggerReason]" -Level Info -Scope $VM.Name
        return New-RotationRecord @record -Result 'WhatIf' -PreviousSecretVersion $previousVersion -Detail 'WhatIf mode, no changes made'
    }

    if (-not (Test-VMRunning -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name)) {
        Write-RotationLog -Message "VM is not running, skipping. The next run will retry." -Level Warning -Scope $VM.Name
        return New-RotationRecord @record -Result 'Skipped' -PreviousSecretVersion $previousVersion -Detail 'VM not running'
    }

    # ---- 1. stage the value -------------------------------------------------
    $pending = Get-PendingCredential -VaultName $VaultName -PendingName $pendingName

    if ($pending.IsOpen) {
        Write-RotationLog -Message "Resuming an interrupted rotation from $($pending.CreatedAt)" -Level Warning -Scope $VM.Name
        $secretValue = $pending.Value
        $publicKey = if ($CredentialType -eq 'SSHKey') {
            ConvertFrom-PemToSshPublicKey -PrivateKeyPem $secretValue
        }
        else { $null }
    }
    else {
        if ($CredentialType -eq 'Password') {
            $secretValue = New-RotationPassword
            $publicKey = $null
        }
        else {
            $keyPair = New-RotationSshKeyPair
            $secretValue = $keyPair.PrivateKey
            $publicKey = $keyPair.PublicKey
        }

        # No public key here: Key Vault caps a tag value at 256 characters and an
        # ssh-rsa key is several times that. On resume it is derived from the staged
        # private key instead.
        $pendingTags = @{
            State     = 'pending'
            VMName    = $VM.Name
            AdminName = $adminUsername
            CreatedAt = $startedAt.ToString('o')
        }

        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $pendingName `
            -SecretValue $secretValue `
            -Expires $startedAt.AddDays(1) `
            -Tag $pendingTags `
            -ErrorAction Stop

        Write-RotationLog -Message "Staged new $CredentialType in '$pendingName'" -Level Info -Scope $VM.Name
    }

    # ---- 2. apply it to the machine ----------------------------------------
    try {
        Set-VMAccessCredential -VM $VM -AdminUsername $adminUsername -OSType $osType `
            -CredentialType $CredentialType -SecretValue $secretValue -PublicKey $publicKey `
            -RemovePriorSshKeys:$RemovePriorSshKeys -ResetSshConfiguration:$ResetSshConfiguration

        Write-RotationLog -Message "VM accepted the new $CredentialType" -Level Success -Scope $VM.Name
    }
    catch {
        Write-RotationLog -Message "VM did not accept the new ${CredentialType}: $($_.Exception.Message)" -Level Error -Scope $VM.Name
        return New-RotationRecord @record -Result 'Failed' -PreviousSecretVersion $previousVersion `
            -Detail "VMAccess extension failed: $($_.Exception.Message). Staged value remains in '$pendingName'."
    }

    # ---- 3. promote ---------------------------------------------------------
    # Tags are replaced wholesale, which also clears RotationReason from a previous
    # access-driven cycle. Leaving it in place would make every later rotation of this
    # secret claim to have been triggered by a read.
    $tags = @{
        VMName         = $VM.Name
        AdminName      = $adminUsername
        OSType         = $osType
        CredentialType = $CredentialType
        LastRotated    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        LastTrigger    = $TriggerReason
        RotatedBy      = 'azure-vm-credential-rotation'
    }

    $new = Set-AzKeyVaultSecret -VaultName $VaultName -Name $secretName `
        -SecretValue $secretValue `
        -Expires (Get-Date).ToUniversalTime().AddDays($ValidityDays) `
        -Tag $tags `
        -ErrorAction Stop

    # The public key is not secret, but keeping it beside the private key saves
    # anyone from having to derive it later.
    if ($CredentialType -eq 'SSHKey' -and $publicKey) {
        $publicName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind 'ssh-pub' -ResourceGroupName $VM.ResourceGroupName -Template $SecretNameTemplate
        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $publicName `
            -SecretValue (ConvertTo-SecureString -String $publicKey -AsPlainText -Force) `
            -Expires (Get-Date).ToUniversalTime().AddDays($ValidityDays) `
            -Tag $tags -ErrorAction Stop
    }

    # ---- 4. close the staging secret ---------------------------------------
    Close-PendingCredential -VaultName $VaultName -PendingName $pendingName

    Write-RotationLog -Message "Rotated $CredentialType, new version $($new.Version), expires in $ValidityDays days" -Level Success -Scope $VM.Name

    return New-RotationRecord @record -Result 'Rotated' `
        -PreviousSecretVersion $previousVersion -NewSecretVersion $new.Version
}

function Get-PendingCredential {
    <#
    .SYNOPSIS
        Returns the staged credential for a secret, if a rotation was interrupted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$PendingName
    )

    $result = [pscustomobject]@{
        IsOpen    = $false
        Value     = $null
        Version   = $null
        CreatedAt = $null
    }

    $meta = Get-RotationSecret -VaultName $VaultName -Name $PendingName
    if (-not $meta.Exists) { return $result }
    if ($meta.Disabled) { return $result }
    if ($meta.Secret.Tags.State -ne 'pending') { return $result }

    # Reading the staged value is a SecretGet by the managed identity. It carries no
    # upn claim, so it never registers as human access.
    $full = Get-AzKeyVaultSecret -VaultName $VaultName -Name $PendingName -ErrorAction Stop

    $result.IsOpen = $true
    $result.Value = $full.SecretValue
    $result.Version = $meta.Secret.Version
    $result.CreatedAt = $meta.Secret.Tags.CreatedAt

    return $result
}

function Close-PendingCredential {
    <#
    .SYNOPSIS
        Marks a staged credential as consumed and removes its value.

    .DESCRIPTION
        Overwrites the staging secret with a placeholder rather than deleting or
        disabling it. All three options were tried against a real vault; only this one
        works:

          delete   Key Vault soft-delete reserves the name until it is purged, so the
                   next rotation fails writing to it. Purging needs another permission
                   and is irreversible.

          disable  reads then fail with "Operation get is not allowed on a disabled
                   secret" - a 403, indistinguishable at a glance from a missing role
                   assignment. Since the engine deliberately refuses to treat an
                   unreadable secret as absent, one disabled staging secret took down
                   discovery for the entire subscription.

          overwrite  the value is gone, the metadata stays readable, the name stays
                     usable. This one.

        The previous version still holds the credential, reachable only by explicit
        version id - but that is the same value now stored in the live secret, so it
        adds no exposure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$PendingName
    )

    try {
        $placeholder = ConvertTo-SecureString -String 'consumed' -AsPlainText -Force

        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $PendingName `
            -SecretValue $placeholder `
            -Expires (Get-Date).ToUniversalTime().AddDays(1) `
            -Tag @{ State = 'consumed'; ConsumedAt = (Get-Date).ToUniversalTime().ToString('o') } `
            -ErrorAction Stop
    }
    catch {
        # The credential is safely in place at this point; a stale staging marker is
        # cosmetic and gets overwritten by the next rotation.
        Write-RotationLog -Message "Could not close staging secret '$PendingName': $($_.Exception.Message)" -Level Warning
    }
}

function Set-VMAccessCredential {
    <#
    .SYNOPSIS
        Applies a credential to a VM through the VMAccess extension.

    .DESCRIPTION
        Note what this does beyond changing a password: if the account named in the
        OS profile no longer exists on the machine, VMAccess recreates it as a local
        administrator. Someone may have removed or renamed that account on purpose.
        See docs/threat-model.md.

        Two hard-won details, both found on a live tenant and neither obvious:

        1. Settings are passed as JSON strings, not hashtables. Handing a hashtable to
           -ProtectedSettings works fine with a current Az module and fails inside an
           Azure Automation sandbox running an older one, where the extension receives
           a nested object and reports:

               Enable failed: crypt() argument 1 must be str, not dict

           The same call, same password, succeeded locally on Az.Accounts 5.5 and
           failed on the sandbox's 2.15. Serialising explicitly removes the module
           version from the equation entirely.

        2. On Linux the optional keys are omitted rather than sent as false, because
           the extension branches on whether a key is *present*, not on its value.

        The Linux extension is also picky about an absent settings object, so an empty
        one is always sent - matching what "az vm user update" does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][string]$OSType,
        [Parameter(Mandatory)][string]$CredentialType,
        [Parameter(Mandatory)][securestring]$SecretValue,
        [string]$PublicKey,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration
    )

    $common = @{
        ResourceGroupName = $VM.ResourceGroupName
        VMName            = $VM.Name
        Location          = $VM.Location
        ForceRerun        = (New-Guid).Guid
        ErrorAction       = 'Stop'
    }

    if ($OSType -eq 'Windows') {
        $plain = ConvertFrom-SecureString -SecureString $SecretValue -AsPlainText
        try {
            $null = Set-AzVMExtension @common `
                -Name 'VMAccessAgent' `
                -Publisher 'Microsoft.Compute' `
                -ExtensionType 'VMAccessAgent' `
                -TypeHandlerVersion '2.4' `
                -SettingString (ConvertTo-Json -InputObject @{ UserName = $AdminUsername } -Compress) `
                -ProtectedSettingString (ConvertTo-Json -InputObject @{ Password = $plain } -Compress)
        }
        finally {
            $plain = $null
            [System.GC]::Collect()
        }
        return
    }

    $protected = @{ username = $AdminUsername }

    if ($CredentialType -eq 'Password') {
        $plain = ConvertFrom-SecureString -SecureString $SecretValue -AsPlainText
        $protected['password'] = $plain
        # No reset_ssh here at all - see the note above.
    }
    else {
        if ([string]::IsNullOrWhiteSpace($PublicKey)) {
            throw 'SSH rotation requires a public key.'
        }
        $protected['ssh_key'] = $PublicKey

        # Present only when actually wanted, for the same reason.
        if ($ResetSshConfiguration) { $protected['reset_ssh'] = $true }
        if ($RemovePriorSshKeys) { $protected['remove_prior_keys'] = $true }
    }

    try {
        $null = Set-AzVMExtension @common `
            -Name 'VMAccessForLinux' `
            -Publisher 'Microsoft.OSTCExtensions' `
            -ExtensionType 'VMAccessForLinux' `
            -TypeHandlerVersion '1.5' `
            -SettingString '{}' `
            -ProtectedSettingString (ConvertTo-Json -InputObject $protected -Compress)
    }
    finally {
        $protected['password'] = $null
        $protected = $null
        $plain = $null
        [System.GC]::Collect()
    }
}

#endregion Public

#region runbook

$ErrorActionPreference = 'Stop'

# Importing the Az modules emits several hundred verbose lines per job, which buries
# everything useful. Silencing the preference keeps them out; Write-RotationLog passes
# -Verbose explicitly so its own lines still come through.
$VerbosePreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# configuration helpers
# ---------------------------------------------------------------------------

function Get-RunbookSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value,
        $Default
    )

    $isSet = $null -ne $Value -and
             -not ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) -and
             -not ($Value -is [int] -and $Value -eq 0)

    if ($isSet) { return $Value }

    try {
        $fromVariable = Get-AutomationVariable -Name "CR_$Name" -ErrorAction Stop
        if ($null -ne $fromVariable -and -not ([string]::IsNullOrWhiteSpace([string]$fromVariable))) {
            return $fromVariable
        }
    }
    catch {
        # Variable not present. Expected whenever an optional module is not deployed,
        # so this is a normal path rather than an error.
        Write-Verbose "Automation variable CR_$Name not set, using the default."
    }

    return $Default
}

# ---------------------------------------------------------------------------
# authenticate
# ---------------------------------------------------------------------------

# Keeps contexts from leaking between concurrent jobs in the same sandbox.
$null = Disable-AzContextAutosave -Scope Process

# Two ways this file reaches Automation, and it has to work for both. The Bicep deployment imports
# the AzureVMCredentialRotation module from the Gallery and publishes this wrapper as it stands, so the
# module has to be imported here. The Terraform deployment publishes the flattened artefact from
# build/Build-Runbook.ps1, which inlines every function ahead of this line - there the commands are
# already defined and importing would pull a second, possibly older copy over them.
if (-not (Get-Command -Name 'Invoke-CredentialRotation' -ErrorAction SilentlyContinue)) {
    Import-Module -Name 'AzureVMCredentialRotation' -ErrorAction Stop
}

Write-Verbose "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) [Info] Connecting with the managed identity" -Verbose
$null = Connect-AzAccount -Identity -ErrorAction Stop

# The identity may hold roles in several subscriptions, and Connect-AzAccount then picks the
# first one it sees - measured: with a machine in a second subscription, the job started in
# that one, and the concurrent-job check below looked for the automation account there,
# failed, and let two jobs run side by side. So the context is pinned to the account's own
# subscription before anything else reads it.
$homeSubscriptionId = [string](Get-RunbookSetting -Name 'AutomationSubscriptionId' -Default '')
if (-not $homeSubscriptionId) {
    # Deployments older than this variable: find the account among the subscriptions the
    # identity can see.
    $homeAccount = Get-RunbookSetting -Name 'AutomationAccountName' -Default ''
    $homeGroup = Get-RunbookSetting -Name 'AutomationResourceGroup' -Default ''
    foreach ($candidate in @(Get-AzSubscription -ErrorAction SilentlyContinue)) {
        $null = Set-AzContext -SubscriptionId $candidate.Id -ErrorAction SilentlyContinue
        if ($homeAccount -and $homeGroup -and (Get-AzResource -ResourceGroupName $homeGroup -Name $homeAccount -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction SilentlyContinue)) {
            $homeSubscriptionId = $candidate.Id
            break
        }
    }
}
if ($homeSubscriptionId) {
    $null = Set-AzContext -SubscriptionId $homeSubscriptionId -ErrorAction Stop
}
else {
    Write-Warning 'Could not determine the automation account''s own subscription; the concurrent-job check and the default subscription may be wrong.'
}

# ---------------------------------------------------------------------------
# resolve configuration
# ---------------------------------------------------------------------------

$config = @{
    VaultName             = Get-RunbookSetting -Name 'VaultName' -Value $VaultName
    ThresholdDays         = [int](Get-RunbookSetting -Name 'ThresholdDays' -Value $ThresholdDays -Default 14)
    ValidityDays          = [int](Get-RunbookSetting -Name 'ValidityDays' -Value $ValidityDays -Default 90)
    EnableTagName         = Get-RunbookSetting -Name 'EnableTagName' -Value $EnableTagName -Default 'CredentialRotation'
    EnableTagValue        = Get-RunbookSetting -Name 'EnableTagValue' -Value $EnableTagValue -Default 'enabled'
    SecretNameTemplate    = Get-RunbookSetting -Name 'SecretNameTemplate' -Value $SecretNameTemplate -Default '{vm}-{user}-{kind}'
    SkipSshKeys           = $SkipSshKeys
    RemovePriorSshKeys    = $RemovePriorSshKeys
    ResetSshConfiguration = $ResetSshConfiguration
}

if ([string]::IsNullOrWhiteSpace($config.VaultName)) {
    throw 'No vault name. Pass -VaultName or set the automation variable CR_VaultName.'
}

# A [bool] parameter cannot say "not given", so the variable is consulted only when the
# parameter was left out - which is what the scheduled job does.
if (-not $PSBoundParameters.ContainsKey('DryRun')) {
    $DryRun = [System.Convert]::ToBoolean([string](Get-RunbookSetting -Name 'DryRun' -Default 'false'))
}

$subscriptions = if ($SubscriptionId) {
    $SubscriptionId -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
else {
    $fromVariable = Get-RunbookSetting -Name 'SubscriptionId' -Default ''
    if ($fromVariable) { $fromVariable -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $null }
}

# Optional: access-driven rotation, present only when the modules are deployed.
$workspaceId = Get-RunbookSetting -Name 'WorkspaceId' -Default ''
$accessEnabled = [bool]::TryParse([string](Get-RunbookSetting -Name 'AccessRotationEnabled' -Default 'false'), [ref]$null) -and
                 ([string](Get-RunbookSetting -Name 'AccessRotationEnabled' -Default 'false')) -eq 'true'

if (-not $accessEnabled) { $workspaceId = '' }

$optional = @{}
if ($workspaceId) {
    $optional['WorkspaceId'] = $workspaceId
    $optional['GracePeriodHours'] = [int](Get-RunbookSetting -Name 'GracePeriodHours' -Default 8)
    $optional['AccessLookbackHours'] = [int](Get-RunbookSetting -Name 'AccessLookbackHours' -Default 24)

    $exclude = [string](Get-RunbookSetting -Name 'ExcludeObjectId' -Default '')
    if ($exclude) {
        $optional['ExcludeObjectId'] = $exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
}

$dce = Get-RunbookSetting -Name 'DataCollectionEndpoint' -Default ''
$dcr = Get-RunbookSetting -Name 'DataCollectionRuleId' -Default ''
if ($dce -and $dcr) {
    $optional['DataCollectionEndpoint'] = $dce
    $optional['DataCollectionRuleId'] = $dcr
    $optional['StreamName'] = Get-RunbookSetting -Name 'StreamName' -Default 'Custom-CredentialRotation_CL'
}

# ---------------------------------------------------------------------------
# guard against overlapping runs
# ---------------------------------------------------------------------------

$accountName = Get-RunbookSetting -Name 'AutomationAccountName' -Default ''
$accountRg = Get-RunbookSetting -Name 'AutomationResourceGroup' -Default ''

if ($accountName -and $accountRg -and $PSPrivateMetadata.JobId) {
    try {
        $thisJobId = $PSPrivateMetadata.JobId.Guid
        $running = Get-AzAutomationJob -ResourceGroupName $accountRg -AutomationAccountName $accountName `
            -RunbookName 'Invoke-CredentialRotation' -ErrorAction Stop |
            Where-Object { $_.Status -in @('Running', 'Starting', 'Activating') -and $_.JobId -ne $thisJobId }

        if ($running) {
            Write-Warning "Another rotation job is already running ($($running[0].JobId)). Exiting so the two cannot fight over the same VM."
            return
        }
    }
    catch {
        Write-Warning "Could not check for concurrent jobs, continuing: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# orchestrate
#
# This is the layer that decides which machines are in scope. The module does not:
# it rotates the machines it is given and has no opinion about tags. Keeping the
# policy here is what lets the same module run from a workstation against one machine
# and from this runbook against a fleet.
# ---------------------------------------------------------------------------

function Get-AccessedSecret {
    # Who read a credential, from the Key Vault audit log. This is the orchestrator's
    # finding, not the module's: the module takes a secret name and a reader and acts.
    # The same KQL lives in queries/accessed-secrets.kql for running by hand.
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$VaultName,
        [int]$LookbackHours = 24,
        [string[]]$ExcludeObjectId = @()
    )

    $excludeClause = ''
    if ($ExcludeObjectId.Count -gt 0) {
        $list = ($ExcludeObjectId | ForEach-Object { "'$($_ -replace "'", '')'" }) -join ', '
        $excludeClause = "| where tostring(Identity.claim.oid) !in ($list)"
    }

    # AZKVAuditLogs is the resource-specific table; the diagnostic setting has to use
    # the Dedicated destination type for it to exist. Only reads with a upn claim count -
    # an application identity reading its own credential is not exposure.
    $query = @"
AZKVAuditLogs
| where TimeGenerated > ago(${LookbackHours}h)
| where OperationName == 'SecretGet'
| where ResultType == 'Success'
| where tolower(tostring(split(_ResourceId, '/')[-1])) == tolower('$VaultName')
| extend Upn = tostring(Identity.claim.upn)
| where isnotempty(Upn)
$excludeClause
| extend SecretName = tostring(split(tostring(parse_url(RequestUri).Path), '/')[2])
| where isnotempty(SecretName)
| summarize LastAccessedAt = max(TimeGenerated), AccessCount = count() by SecretName, Upn
| project SecretName, LastAccessedAt, AccessedBy = Upn, AccessCount
"@

    $response = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
    foreach ($row in @($response.Results)) {
        [pscustomobject]@{
            SecretName     = [string]$row.SecretName
            LastAccessedAt = [datetime]$row.LastAccessedAt
            AccessedBy     = [string]$row.AccessedBy
            AccessCount    = [int]$row.AccessCount
        }
    }
}

function Write-RotationRecord {
    # One structured record to the custom table, through the Logs Ingestion API (the
    # HTTP Data Collector API retires on 14 September 2026). The module returns records;
    # where they go is decided here, next to the infrastructure that receives them.
    #
    # Failure to write a record is a warning, not a failure: the credential change already
    # happened, and the job output carries the same information.
    param(
        [Parameter(Mandatory, ValueFromPipeline)][pscustomobject]$Record,
        [Parameter(Mandatory)][string]$DataCollectionEndpoint,
        [Parameter(Mandatory)][string]$DataCollectionRuleId,
        [string]$StreamName = 'Custom-CredentialRotation_CL'
    )

    process {
        try {
            # Az.Accounts 5 returns the token as a SecureString; the sandbox's older module returns
            # a string. Accept both, so the same wrapper works in Automation and at a prompt.
            $token = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop).Token
            if ($token -is [securestring]) { $token = ConvertFrom-SecureString -SecureString $token -AsPlainText }
            $uri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f
                $DataCollectionEndpoint.TrimEnd('/'), $DataCollectionRuleId, $StreamName
            $body = ConvertTo-Json -InputObject @($Record) -Depth 5 -Compress

            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
                -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $token" } `
                -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not write rotation record for $($Record.SecretName): $($_.Exception.Message)"
        }
    }
}

function Test-TagValue {
    # Azure tag keys are case-insensitive, and a tag typed in the portal as
    # "credentialrotation" must count. Hashtable lookup is not, so match on the key.
    param($Tags, [string]$Name, [string]$Value)
    if (-not $Tags) { return $false }
    $key = $Tags.Keys | Where-Object { $_ -ieq $Name } | Select-Object -First 1
    if (-not $key) { return $false }
    return ([string]$Tags[$key]) -eq $Value
}

$targetSubscriptions = if ($subscriptions) { $subscriptions } else { @((Get-AzContext).Subscription.Id) }

$totals = [ordered]@{ Candidates = 0; Rotated = 0; Skipped = 0; Failed = 0; AccessMarked = 0 }

# Rotation after use, once for the whole run: it moves expiry dates in the vault, and
# the per-subscription passes below then see those credentials as ordinary ageing.
if ($workspaceId) {
    try {
        $queryParams = @{
            VaultName     = $config.VaultName
            WorkspaceId   = $workspaceId
            LookbackHours = $optional['AccessLookbackHours']
        }
        if ($optional.ContainsKey('ExcludeObjectId')) { $queryParams['ExcludeObjectId'] = $optional['ExcludeObjectId'] }

        $reads = @(Get-AccessedSecret @queryParams)
        Write-Verbose "$($reads.Count) secret(s) read by a person in the last $($optional['AccessLookbackHours']) h" -Verbose

        # No template here on purpose: the audit log reports the secret name that was read,
        # so the name arrives from the vault rather than being rebuilt.
        $marked = @($reads | Register-CredentialAccess -VaultName $config.VaultName `
                -GracePeriodHours $optional['GracePeriodHours'] -WhatIf:$DryRun -Confirm:$false)
        $totals.AccessMarked = @($marked | Where-Object { $_.Applied }).Count
    }
    catch {
        # A workspace problem must not stop expiry-driven rotation.
        Write-Warning "Access scan failed, continuing with expiry-driven rotation only: $($_.Exception.Message)"
        $totals.Failed++
    }
}

foreach ($sub in $targetSubscriptions) {
    Write-Verbose "--- Subscription $sub ---" -Verbose

    try {
        $null = Set-AzContext -SubscriptionId $sub -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot switch to subscription ${sub}: $($_.Exception.Message)"
        $totals.Failed++
        continue
    }

    try {
        # Opt-in, not opt-out. A discovery loop that treated "no secret exists for this
        # VM" as "rotate it" would, on its first run in an established tenant, change the
        # local administrator password of every machine it can see - including the ones
        # whose credentials live in a CMDB nobody told it about.
        $all = @(Get-AzVM -ErrorAction Stop)
        $enabled = @($all | Where-Object { Test-TagValue -Tags $_.Tags -Name $config.EnableTagName -Value $config.EnableTagValue })
        $held = @($enabled | Where-Object { Test-TagValue -Tags $_.Tags -Name $HoldTagName -Value 'true' })
        $machines = @($enabled | Where-Object { $_ -notin $held })
    }
    catch {
        Write-Warning "Discovery failed in subscription ${sub}: $($_.Exception.Message)"
        $totals.Failed++
        continue
    }

    Write-Verbose "$($enabled.Count) VM(s) tagged $($config.EnableTagName)=$($config.EnableTagValue), $($held.Count) on hold via $HoldTagName" -Verbose
    foreach ($vm in $held) { Write-Verbose "[$($vm.Name)] on hold, skipping" -Verbose }

    if ($machines.Count -eq 0) { continue }

    # The list form of Get-AzVM has no OSProfile, and the rotation needs the admin
    # username off it. Fetch each selected machine in full before handing it over.
    $full = foreach ($vm in $machines) {
        try { Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop }
        catch {
            Write-Warning "Could not read $($vm.Name) in full: $($_.Exception.Message)"
            $totals.Failed++
        }
    }
    $full = @($full)
    if ($full.Count -eq 0) { continue }

    $params = @{
        VaultName             = $config.VaultName
        VM                    = $full
        # A scheduled pass replaces what is due, not everything it can see. The module
        # rotates whatever it is handed unless told otherwise, so this switch is what
        # keeps a six-hourly job from re-rolling every credential in the estate.
        OnlyIfDue             = $true
        ThresholdDays         = $config.ThresholdDays
        ValidityDays          = $config.ValidityDays
        SecretNameTemplate    = $config.SecretNameTemplate
        SkipSshKeys           = $config.SkipSshKeys
        RemovePriorSshKeys    = $config.RemovePriorSshKeys
        ResetSshConfiguration = $config.ResetSshConfiguration
        TriggeredBy           = 'automation'
    }

    $result = Invoke-CredentialRotation @params -WhatIf:$DryRun -Confirm:$false

    # The module returned the records; this is where they go. Only when the observability
    # deployment exists - without it the job output is the trail, which is fine.
    if ($optional.ContainsKey('DataCollectionEndpoint') -and -not $DryRun -and @($result.Records).Count -gt 0) {
        $result.Records | Write-RotationRecord -DataCollectionEndpoint $optional['DataCollectionEndpoint'] `
            -DataCollectionRuleId $optional['DataCollectionRuleId'] -StreamName $optional['StreamName']
    }

    $totals.Candidates += $result.Candidates
    $totals.Rotated += $result.Rotated
    $totals.Skipped += $result.Skipped
    $totals.Failed += $result.Failed
}

$summary = [pscustomobject]$totals

if ($DryRun) {
    Write-Warning 'DRY RUN - nothing was changed'
}

# The headline numbers go to the output stream, not the verbose one, so they survive
# even if someone deploys with verbose logging turned off.
Write-Output ("Rotation summary: candidates={0} rotated={1} skipped={2} failed={3} accessMarked={4}" -f `
    $summary.Candidates, $summary.Rotated, $summary.Skipped, $summary.Failed, $summary.AccessMarked)

# A runbook that swallows its errors reports Completed, and every alert built on job
# status is then blind. Throw so the job status reflects reality.
if ($summary.Failed -gt 0) {
    throw "Credential rotation finished with $($summary.Failed) failure(s). See the job output for detail."
}

#endregion runbook
