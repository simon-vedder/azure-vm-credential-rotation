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
