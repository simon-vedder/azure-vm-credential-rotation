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
