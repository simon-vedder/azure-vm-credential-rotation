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

    .PARAMETER Template
        How the name is built, with {vm}, {user} and {kind} as placeholders. The default
        is the shape this tool has always used. It has to contain {vm} and {kind}: without
        the first every machine lands on the same secret, without the second a password
        and an SSH key do. {user} is optional, for vaults that already key by machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][ValidateSet('pw', 'ssh-priv', 'ssh-pub')][string]$Kind,
        [switch]$Pending,
        [ValidateNotNullOrEmpty()][string]$Template = '{vm}-{user}-{kind}'
    )

    foreach ($required in '{vm}', '{kind}') {
        if ($Template -notlike "*$required*") {
            throw "Secret name template '$Template' must contain $required, otherwise different credentials collide on one secret."
        }
    }

    $normalise = {
        param($value)
        ($value -replace '[^a-zA-Z0-9-]', '-') -replace '-+', '-'
    }

    $name = $Template.
        Replace('{vm}', (& $normalise $VMName)).
        Replace('{user}', (& $normalise $AdminUsername)).
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
