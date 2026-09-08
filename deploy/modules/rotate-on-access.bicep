// Resource-group scope: turns on rotation after use.
//
// Deliberately thin. The logic lives in the runbook; this is the switch and its settings. That is
// what makes it independently deployable: add it and reads start pulling expiry dates forward,
// remove it and the system falls back to plain calendar rotation without anything else changing.
//
// Requires the observability module, because the mechanism is a query against the Key Vault audit
// log in the workspace that module creates.
targetScope = 'resourceGroup'

param automationAccountName string

@description('Hours a credential stays valid after somebody read it. The read moves the expiry date this far forward, and the next reconciliation pass replaces it.')
param gracePeriodHours int

@description('How far back the run looks for reads. Must exceed the schedule interval, or reads that land between two runs are dropped silently - the worst kind of failure here, because nothing reports it. Main.bicep defaults it to twice the interval.')
param accessLookbackHours int

@description('Object IDs excluded from access detection, comma-joined. The automation identity is always included by main.bicep, so the tool can never trigger itself.')
param excludedObjectIds string

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' existing = {
  name: automationAccountName
}

var settings = {
  CR_AccessRotationEnabled: 'true'
  CR_GracePeriodHours: string(gracePeriodHours)
  CR_AccessLookbackHours: string(accessLookbackHours)
  CR_ExcludeObjectId: excludedObjectIds
}

resource variables 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [
  for setting in items(settings): {
    parent: automationAccount
    name: setting.key
    properties: {
      isEncrypted: false
      value: '"${setting.value}"'
    }
  }
]
