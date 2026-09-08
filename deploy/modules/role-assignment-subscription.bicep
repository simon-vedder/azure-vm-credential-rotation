// Virtual Machine Contributor across the whole subscription. Used only when no resource groups are
// named - see the warning in role-assignment-resourcegroup.bicep about what this role permits.
targetScope = 'subscription'

param principalId string

resource vmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
