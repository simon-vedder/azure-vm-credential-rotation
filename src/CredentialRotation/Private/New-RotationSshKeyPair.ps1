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
