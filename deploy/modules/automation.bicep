// Resource-group scope: the rotation engine. Automation Account with a system-assigned identity,
// the AzureVMCredentialRotation module from the Gallery, the runbook wrapper, the schedule that runs it,
// and the settings the runbook reads at start-up.
//
// This is the equivalent of the Terraform `core` module. Deploy it alone and you get expiry-driven
// rotation; observability and rotation-after-use layer on top by adding more CR_* variables.
targetScope = 'resourceGroup'

param location string
param automationAccountName string
param tags object

@description('Where the AzureVMCredentialRotation module package comes from. A PowerShell Gallery URL, or a GitHub release asset before the first Gallery release.')
param modulePackageUri string

@description('Raw URL of the runbook wrapper. Pin it to a tag in production.')
param runbookContentUri string

@description('Version stamp for the module package and runbook content. Change it to force a re-import of an unchanged URI.')
param contentVersion string

@description('A value unique to this deployment, used to seed the job schedule id. See the note on that resource.')
param deploymentStamp string

@description('Name of the existing Key Vault that stores the credentials. The runbook addresses the vault by name.')
param keyVaultName string

@description('Subscriptions the runbook processes, comma-joined. Empty means the automation account\'s own subscription only.')
param targetSubscriptionIds string

param thresholdDays int
param validityDays int
param enableTagName string
param enableTagValue string

param scheduleIntervalHours int
param scheduleStartTime string
param scheduleTimeZone string

@description('Run the schedule under -WhatIf: report what would be rotated, change nothing. Deploy with this on, read one run, then turn it off.')
param dryRun bool

@description('Enable the verbose job stream. On by default, which is not the usual advice - Automation drops the stream entirely when this is off, and verbose is the only stream the rotation logic can write to that is both visible in the portal and safe inside a function that returns a value.')
param logVerbose bool

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: true
  }
}

// The version property is what makes ARM re-import when the package behind an unchanged URI moved.
// Without it a redeploy with the same URI is a no-op.
resource rotationModule 'Microsoft.Automation/automationAccounts/powershell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'AzureVMCredentialRotation'
  properties: {
    contentLink: {
      uri: modulePackageUri
      version: contentVersion
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-CredentialRotation'
  location: location
  tags: tags
  properties: {
    // 'PowerShell72' selects the PowerShell 7.2 runtime; 'PowerShell' would be Windows PowerShell 5.1.
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose: logVerbose
    description: 'Reconciles Azure VM credentials against their Key Vault expiry dates.'
    publishContentLink: {
      uri: runbookContentUri
      version: contentVersion
    }
  }
  dependsOn: [
    rotationModule
  ]
}

// Automation schedules run at most hourly. The interval is the worst-case delay between a
// credential being marked for rotation and it actually being replaced, which matters most for
// rotation after use: total exposure is roughly the grace period plus this interval.
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-CredentialRotation-every-${scheduleIntervalHours}h'
  properties: {
    description: 'Reconciliation pass. Also the retry mechanism: anything skipped or failed is picked up next run.'
    frequency: 'Hour'
    interval: scheduleIntervalHours
    startTime: scheduleStartTime
    timeZone: scheduleTimeZone
  }
}

// Two things about this resource were measured against a live account, and both shape it.
//
// The id carries a per-deployment stamp. Automation keeps job-schedule ids after the account is
// deleted, so an id derived from names alone collides the moment the same names are deployed
// again: "A jobSchedule with same id already exists", on an account with no job schedules at all.
// A fresh id per deployment does not pile up links, because Automation treats a PUT for a
// runbook-schedule pair that is already linked as a no-op.
//
// That same no-op is why there are no parameters here. A redeployment cannot change them - the
// PUT reports success and the link keeps what it had - so dryRun is read from CR_DryRun instead,
// which ARM updates reliably.
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, 'rotation', runbook.name, deploymentStamp)
  properties: {
    schedule: {
      name: schedule.name
    }
    runbook: {
      name: runbook.name
    }
  }
}

// The runbook resolves parameter, then Automation variable, then default. An absent variable is
// how the runbook is told to use its default, so the optional subscription list is a conditional
// resource rather than a variable written empty.
var coreSettings = {
  CR_VaultName: keyVaultName
  CR_ThresholdDays: string(thresholdDays)
  CR_ValidityDays: string(validityDays)
  CR_EnableTagName: enableTagName
  CR_EnableTagValue: enableTagValue
  CR_AutomationAccountName: automationAccountName
  CR_AutomationResourceGroup: resourceGroup().name
  CR_AutomationSubscriptionId: subscription().subscriptionId
  CR_DryRun: string(dryRun)
}

resource coreVariables 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [
  for setting in items(coreSettings): {
    parent: automationAccount
    name: setting.key
    properties: {
      isEncrypted: false
      // Automation stores variable values as JSON, so a string value carries its own quotes.
      value: '"${setting.value}"'
    }
  }
]

resource subscriptionVariable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (!empty(targetSubscriptionIds)) {
  parent: automationAccount
  name: 'CR_SubscriptionId'
  properties: {
    isEncrypted: false
    value: '"${targetSubscriptionIds}"'
    description: 'Subscriptions the runbook processes. Absent means the automation account\'s own subscription only.'
  }
}

// The runbook checks whether another instance of itself is already running before it starts work.
// Without this role that check throws, gets caught, and silently protects nothing - which is
// exactly how it behaved on the first live run.
resource jobOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'job-operator', '4fe576fe-1146-4730-92eb-48519fa6bf9f')
  scope: automationAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4fe576fe-1146-4730-92eb-48519fa6bf9f')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output principalId string = automationAccount.identity.principalId
output automationAccountId string = automationAccount.id
output automationAccountName string = automationAccount.name
output runbookName string = runbook.name
