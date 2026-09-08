// Resource-group scope, at the vault's resource group: routes the Key Vault audit log into the
// workspace. Its own module because the vault normally lives in a different resource group from
// the automation account, and a diagnostic setting has to be deployed where its target is.
//
// logAnalyticsDestinationType 'Dedicated' is what routes audit events into the resource-specific
// AZKVAuditLogs table instead of the generic AzureDiagnostics one. The runbook's query and
// everything in queries/ assume that table; change this and the column names change with it.
targetScope = 'resourceGroup'

param keyVaultName string
param workspaceResourceId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'credential-rotation-audit'
  scope: keyVault
  properties: {
    workspaceId: workspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
    ]
  }
}
