// Resource-group scope: the audit trail. Answers one question end to end - who read a credential,
// when, and when was it replaced afterwards.
//
// Two halves. Key Vault's own audit log supplies the reads for free once a diagnostic setting
// points at a workspace (that setting is keyvault-diagnostics.bicep, because the vault usually
// lives in another resource group). The rotations come from the runbook, written to a custom table
// through the Logs Ingestion API.
//
// This module is also the prerequisite for rotation after use: the workspace is what the runbook
// queries to learn that a credential was read at all.
targetScope = 'resourceGroup'

param location string
param tags object

@description('Create a workspace with this name. Ignored when existingWorkspaceId is set.')
param workspaceName string

@description('Use this existing workspace instead of creating one. Resource ID; empty creates one.')
param existingWorkspaceId string

@description('The GUID of that existing workspace - its customerId, not its resource ID. Required with existingWorkspaceId: the runbook queries by GUID, and reading it off a resource this template did not create would mean referencing a resource that may live in another resource group.')
param existingWorkspaceGuid string

@minValue(30)
@maxValue(730)
param retentionDays int

param automationAccountName string
param automationPrincipalId string

param deployWorkbook bool

// Must match New-RotationRecord in the module and the stream declaration below.
var recordColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'SecretName', type: 'string' }
  { name: 'VMName', type: 'string' }
  { name: 'ResourceGroupName', type: 'string' }
  { name: 'SubscriptionId', type: 'string' }
  { name: 'OSType', type: 'string' }
  { name: 'CredentialType', type: 'string' }
  { name: 'TriggerReason', type: 'string' }
  { name: 'TriggeredBy', type: 'string' }
  { name: 'Result', type: 'string' }
  { name: 'StartedAt', type: 'datetime' }
  { name: 'DurationMs', type: 'int' }
  { name: 'PreviousSecretVersion', type: 'string' }
  { name: 'NewSecretVersion', type: 'string' }
  { name: 'Detail', type: 'string' }
]

var tableName = 'CredentialRotation_CL'
var streamName = 'Custom-CredentialRotation_CL'
var createWorkspace = empty(existingWorkspaceId)

resource newWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (createWorkspace) {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

var workspaceResourceId = createWorkspace ? newWorkspace!.id : existingWorkspaceId

// Invoke-AzOperationalInsightsQuery wants the workspace GUID, not the resource ID. When the
// workspace is borrowed the caller supplies it, so nothing here references a resource in another
// resource group.
var workspaceGuid = createWorkspace ? newWorkspace!.properties.customerId : existingWorkspaceGuid

// The table is created on the workspace this module owns. A borrowed workspace is assumed to
// already carry it - creating a child resource on someone else's workspace is not something a
// template should do behind its owner's back.
resource rotationTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = if (createWorkspace) {
  parent: newWorkspace
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionDays
    schema: {
      name: tableName
      description: 'One record per credential rotation attempt. Contains no credential material - only secret version identifiers.'
      columns: recordColumns
    }
  }
}

// Logs Ingestion API, not the HTTP Data Collector API - the latter retires on 14 September 2026.
resource collectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${automationAccountName}'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource collectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${automationAccountName}'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: collectionEndpoint.id
    description: 'Routes credential rotation records into ${tableName}.'
    streamDeclarations: {
      'Custom-CredentialRotation_CL': {
        columns: recordColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'workspace' ]
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [
    rotationTable
  ]
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' existing = {
  name: automationAccountName
}

resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'credential-rotation-jobs'
  scope: automationAccount
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
  }
}

// Switches the feature on in the runbook without redeploying it. Written one by one rather than
// looped: a for-expression needs its keys at the start of the deployment, and three of these four
// values are only known once the resources above exist.
resource variableWorkspace 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'CR_WorkspaceId'
  properties: {
    isEncrypted: false
    // Automation stores variable values as JSON, so a string value carries its own quotes.
    value: '"${workspaceGuid}"'
    description: 'Workspace GUID the runbook queries for credential reads.'
  }
}

resource variableEndpoint 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'CR_DataCollectionEndpoint'
  properties: {
    isEncrypted: false
    value: '"${collectionEndpoint.properties.logsIngestion.endpoint}"'
    description: 'Logs ingestion endpoint for CredentialRotation_CL.'
  }
}

resource variableRule 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'CR_DataCollectionRuleId'
  properties: {
    isEncrypted: false
    value: '"${collectionRule.properties.immutableId}"'
    description: 'Immutable id of the data collection rule that routes Custom-CredentialRotation_CL.'
  }
}

resource variableStream 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'CR_StreamName'
  properties: {
    isEncrypted: false
    value: '"${streamName}"'
    description: 'Stream the runbook writes rotation records to.'
  }
}

// Log Analytics Reader: query the audit log to find credentials that were read. Only assigned on a
// workspace this module created; on a borrowed one, grant it yourself - the workspace may sit in a
// resource group this deployment has no business writing to.
resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createWorkspace) {
  name: guid(newWorkspace.id, automationPrincipalId, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: newWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Metrics Publisher: the only role the Logs Ingestion API accepts for a writer.
resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(collectionRule.id, automationPrincipalId, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: collectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook) {
  name: guid(workspaceResourceId, 'credential-rotation-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Credential access and rotation'
    category: 'workbook'
    sourceId: toLower(workspaceResourceId)
    version: '1.0'
    serializedData: replace(loadTextContent('workbook.json'), '{workspaceId}', workspaceResourceId)
  }
}

output workspaceResourceId string = workspaceResourceId
output logIngestionEndpoint string = collectionEndpoint.properties.logsIngestion.endpoint
output dataCollectionRuleId string = collectionRule.properties.immutableId
