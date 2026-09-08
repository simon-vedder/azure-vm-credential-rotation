// Virtual Machine Contributor on one resource group of VMs.
//
// Note what this allows: installing extensions, which is how the credential reaches the guest, and
// which is effectively code execution as SYSTEM or root on every VM in scope. Keep it to a
// resource group rather than a subscription wherever you can.
targetScope = 'resourceGroup'

param principalId string

resource vmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
