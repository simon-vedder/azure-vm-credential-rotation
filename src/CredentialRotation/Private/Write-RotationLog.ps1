function Write-RotationLog {
    <#
    .SYNOPSIS
        Writes a structured line to the job log.

    .DESCRIPTION
        Uses Write-Host, not Write-Output.

        Write-Output looks like the right choice for Azure Automation - it lands in the
        job output stream, which is what you read in the portal. But it also writes to
        the success stream, so every log line from a function becomes part of that
        function's return value. A function that logs twice and returns one object
        actually returns three things, and the caller silently gets a mess.

        Write-Host writes to the information stream, which Automation also surfaces in
        the job output, without touching the pipeline.

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

    Write-Host "$timestamp $prefix $Message"

    # Also surface warnings and errors on their own streams, so a failing job is
    # visible in the portal without reading the whole output.
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error -Message $Message -ErrorAction Continue }
    }
}
