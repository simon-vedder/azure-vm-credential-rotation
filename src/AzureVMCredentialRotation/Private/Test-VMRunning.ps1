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
