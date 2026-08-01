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
