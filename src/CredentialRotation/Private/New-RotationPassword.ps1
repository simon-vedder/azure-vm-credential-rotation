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
