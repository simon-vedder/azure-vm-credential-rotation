// Key Vault Secrets Officer on the existing vault: read secret metadata, write rotated
// credentials, update expiry dates. Its own module because the vault usually lives in a different
// resource group from the automation account.
targetScope = 'resourceGroup'

param keyVaultName string
param principalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, principalId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
