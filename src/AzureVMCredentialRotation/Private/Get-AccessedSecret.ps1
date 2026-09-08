function Get-AccessedSecret {
    <#
    .SYNOPSIS
        Returns secrets whose value was read by a human since a given point in time.

    .DESCRIPTION
        This is the whole access-triggered rotation mechanism. No Event Grid, no
        alert rule, no webhook: the run asks Log Analytics who read what, and acts
        on the answer.

        "Human" is approximated by the presence of an upn claim. Service principals
        and managed identities authenticate with an appid and no upn, so an
        application reading its own secret does not trigger a rotation - which is
        the desired behaviour, since rotating under a running workload breaks it.

        Two caveats worth knowing before you rely on this:

        - Log Analytics ingestion is not instant. Several minutes is normal. The
          LookbackHours window should comfortably exceed the schedule interval so a
          delayed record is never missed; overlapping windows are harmless because
          bringing an expiry date forward is idempotent.

        - Column names differ between the resource-specific table (AZKVAuditLogs)
          and the legacy AzureDiagnostics table. This function targets the former,
          which is what the observability module configures. Verify the query in
          your own workspace before trusting it - see queries/accessed-secrets.kql.

    .OUTPUTS
        PSCustomObject with SecretName, LastAccessedAt, AccessedBy, AccessCount.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$VaultName,

        [ValidateRange(1, 720)]
        [int]$LookbackHours = 24,

        # Object IDs never counted as human access, typically the automation
        # account's own managed identity.
        [string[]]$ExcludeObjectId = @()
    )

    $excludeClause = ''
    if ($ExcludeObjectId.Count -gt 0) {
        $list = ($ExcludeObjectId | ForEach-Object { "'$($_ -replace "'", '')'" }) -join ', '
        $excludeClause = "| where tostring(Identity.claim.oid) !in ($list)"
    }

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

    Write-RotationLog -Message "Querying workspace for secret reads in the last $LookbackHours hours" -Level Info -Scope 'access'

    $response = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop

    if (-not $response.Results) { return @() }

    return @($response.Results | ForEach-Object {
        [pscustomobject]@{
            SecretName     = $_.SecretName
            LastAccessedAt = [datetime]::Parse($_.LastAccessedAt).ToUniversalTime()
            AccessedBy     = $_.AccessedBy
            AccessCount    = [int]$_.AccessCount
        }
    })
}
