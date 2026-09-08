// Subscription-scope deployment of credential rotation: resource group, Automation Account with a
// system-assigned identity, the AzureVMCredentialRotation module from the Gallery, the runbook and its
// schedule, the roles the identity needs, and optionally the audit trail and rotation after use.
//
//   az deployment sub create -l switzerlandnorth -f deploy/main.bicep \
//     -p moduleVersion=0.3.0 keyVaultName=kv-creds keyVaultResourceGroupName=rg-vault \
//        targetResourceGroupNames='["rg-workloads"]'
//
// Subscription scope because the Key Vault and the VMs usually live in different resource groups
// from the automation account, and a role assignment has to be made where its scope is.
//
// Nothing rotates by itself on the first deployment: dryRun defaults to true, so the first runs
// report what they would replace and change nothing. Read one, then redeploy with dryRun=false.
targetScope = 'subscription'

@description('Region for the resource group and everything in it.')
param location string = 'switzerlandnorth'

param resourceGroupName string = 'rg-credential-rotation'
param automationAccountName string = 'aa-credential-rotation'

@description('AzureVMCredentialRotation module version on the PowerShell Gallery.')
param moduleVersion string

@description('Version stamp written to the module and runbook content links, System.Version form (up to four numeric parts). Defaults to moduleVersion with any pre-release suffix stripped, because Automation rejects one; bump it to force Automation to re-import unchanged URIs.')
@minLength(0)
param contentVersion string = ''

@description('Override the module package source, for example a GitHub release asset before the first Gallery release. Empty means the Gallery URL for moduleVersion.')
param modulePackageUri string = ''

@description('Raw URL of the runbook wrapper. Pin to a tag in production.')
param runbookContentUri string = 'https://raw.githubusercontent.com/simon-vedder/azure-vm-credential-rotation/main/src/runbooks/Invoke-CredentialRotationRunbook.ps1'

// ---------------------------------------------------------------------------------------------
// the vault
// ---------------------------------------------------------------------------------------------

@description('Name of the existing Key Vault that stores the credentials. Must have RBAC authorisation enabled.')
param keyVaultName string

@description('Resource group holding that Key Vault. It must be in this subscription.')
param keyVaultResourceGroupName string

// ---------------------------------------------------------------------------------------------
// what it may touch
// ---------------------------------------------------------------------------------------------

@description('Resource groups whose VMs the identity may manage. Empty grants Virtual Machine Contributor across the whole subscription instead - keep this list narrow, because that role includes installing extensions, which is code execution as SYSTEM or root on every VM in scope.')
param targetResourceGroupNames array = []

@description('Subscriptions the runbook processes. Empty means the automation account\'s own subscription only.')
param targetSubscriptionIds array = []

@description('VM tag that opts a machine in to rotation.')
param enableTagName string = 'CredentialRotation'

@description('Value that tag must carry.')
param enableTagValue string = 'enabled'

// ---------------------------------------------------------------------------------------------
// timing
// ---------------------------------------------------------------------------------------------

@description('Rotate when a credential expires within this many days. Give it comfortable headroom over the schedule interval: a VM powered off for a few days keeps being retried, and a tight threshold means the secret expires before the machine comes back.')
@minValue(1)
@maxValue(3650)
param thresholdDays int = 14

@description('Lifetime of a newly rotated credential, in days.')
@minValue(1)
@maxValue(3650)
param validityDays int = 90

@description('Hours between reconciliation runs. This is the upper bound on how long a credential marked for rotation waits.')
@minValue(1)
@maxValue(24)
param scheduleIntervalHours int = 6

@description('First run, ISO 8601. Azure requires at least five minutes out; defaults to fifteen minutes from deployment.')
param scheduleStartTime string = dateTimeAdd(baseTime, 'PT15M')

param scheduleTimeZone string = 'Etc/UTC'

@description('Run the schedule under -WhatIf: report what would be rotated, change nothing. On by default. Read one run, then redeploy with this off.')
param dryRun bool = true

@description('Enable the verbose job stream. On by default - Automation drops the stream entirely when this is off, and verbose is the only stream the rotation logic can safely write to.')
param logVerbose bool = true

// ---------------------------------------------------------------------------------------------
// the audit trail
// ---------------------------------------------------------------------------------------------

@description('Deploy the workspace, custom table and diagnostic settings that record who read a credential and when it was replaced. Required for rotation after use.')
param deployObservability bool = true

param workspaceName string = 'log-credential-rotation'

@description('Use this existing workspace instead of creating one. Resource ID; empty creates one. A borrowed workspace is assumed to already carry the CredentialRotation_CL table, and needs Log Analytics Reader granted to the identity separately.')
param existingWorkspaceId string = ''

@description('The GUID of that workspace - its customerId, not its resource ID. Required whenever existingWorkspaceId is set.')
param existingWorkspaceGuid string = ''

@minValue(30)
@maxValue(730)
param retentionDays int = 90

param deployWorkbook bool = true

// ---------------------------------------------------------------------------------------------
// rotation after use
// ---------------------------------------------------------------------------------------------

@description('Turn on rotation after use: a read pulls the expiry date forward so the next pass replaces the credential. Needs deployObservability.')
param enableRotateOnAccess bool = false

@description('Hours a credential stays valid after somebody read it.')
@minValue(1)
@maxValue(720)
param gracePeriodHours int = 8

@description('How far back each run looks for reads. Zero means twice the schedule interval, which is the safe default: a window shorter than the gap between runs drops reads silently.')
@minValue(0)
@maxValue(720)
param accessLookbackHours int = 0

@description('Extra object IDs excluded from access detection. The automation identity is always excluded, so the tool cannot trigger itself.')
param additionalExcludedObjectIds array = []

param tags object = {
  Project: 'azure-vm-credential-rotation'
}

param baseTime string = utcNow()

var effectiveModuleUri = empty(modulePackageUri)
  ? 'https://www.powershellgallery.com/api/v2/package/AzureVMCredentialRotation/${moduleVersion}'
  : modulePackageUri

// Automation rejects a content-link version that is not a System.Version, so a pre-release suffix
// has to come off.
var effectiveContentVersion = empty(contentVersion) ? split(moduleVersion, '-')[0] : contentVersion

// A lookback shorter than the gap between runs drops reads that land between two passes, and
// nothing reports it. Twice the interval is the documented starting point.
var effectiveLookbackHours = accessLookbackHours == 0 ? scheduleIntervalHours * 2 : accessLookbackHours

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module automation 'modules/automation.bicep' = {
  name: 'automation'
  scope: resourceGroup
  params: {
    location: location
    automationAccountName: automationAccountName
    tags: tags
    modulePackageUri: effectiveModuleUri
    runbookContentUri: runbookContentUri
    contentVersion: effectiveContentVersion
    keyVaultName: keyVaultName
    targetSubscriptionIds: join(targetSubscriptionIds, ',')
    thresholdDays: thresholdDays
    validityDays: validityDays
    enableTagName: enableTagName
    enableTagValue: enableTagValue
    scheduleIntervalHours: scheduleIntervalHours
    scheduleStartTime: scheduleStartTime
    scheduleTimeZone: scheduleTimeZone
    dryRun: dryRun
    logVerbose: logVerbose
  }
}

module keyVaultRole 'modules/role-assignment-keyvault.bicep' = {
  name: 'role-key-vault'
  scope: az.resourceGroup(keyVaultResourceGroupName)
  params: {
    keyVaultName: keyVaultName
    principalId: automation.outputs.principalId
  }
}

module vmRoleAtResourceGroup 'modules/role-assignment-resourcegroup.bicep' = [
  for name in targetResourceGroupNames: {
    name: 'role-vm-${name}'
    scope: az.resourceGroup(name)
    params: {
      principalId: automation.outputs.principalId
    }
  }
]

module vmRoleAtSubscription 'modules/role-assignment-subscription.bicep' = if (empty(targetResourceGroupNames)) {
  name: 'role-vm-subscription'
  params: {
    principalId: automation.outputs.principalId
  }
}

module observability 'modules/observability.bicep' = if (deployObservability) {
  name: 'observability'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    workspaceName: workspaceName
    existingWorkspaceId: existingWorkspaceId
    existingWorkspaceGuid: existingWorkspaceGuid
    retentionDays: retentionDays
    automationAccountName: automationAccountName
    automationPrincipalId: automation.outputs.principalId
    deployWorkbook: deployWorkbook
  }
}

module keyVaultDiagnostics 'modules/keyvault-diagnostics.bicep' = if (deployObservability) {
  name: 'key-vault-diagnostics'
  scope: az.resourceGroup(keyVaultResourceGroupName)
  params: {
    keyVaultName: keyVaultName
    workspaceResourceId: observability!.outputs.workspaceResourceId
  }
}

module rotateOnAccess 'modules/rotate-on-access.bicep' = if (enableRotateOnAccess && deployObservability) {
  name: 'rotate-on-access'
  scope: resourceGroup
  params: {
    automationAccountName: automationAccountName
    gracePeriodHours: gracePeriodHours
    accessLookbackHours: effectiveLookbackHours
    excludedObjectIds: join(union([ automation.outputs.principalId ], additionalExcludedObjectIds), ',')
  }
  dependsOn: [
    observability
  ]
}

output automationAccountId string = automation.outputs.automationAccountId
output automationAccountName string = automation.outputs.automationAccountName
output principalId string = automation.outputs.principalId
output runbookName string = automation.outputs.runbookName
output resourceGroupName string = resourceGroup.name
