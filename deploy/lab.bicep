// Lab for verifying azure-vm-credential-rotation against real guests.
//
// Deliberately minimal: one Windows and one Linux VM, no public IP, no inbound rules, and a Key
// Vault with RBAC authorisation. Every check runs through Run Command, so nothing is exposed. The
// Linux VM keeps password authentication on so that both credential kinds - password and SSH key -
// get exercised. Deallocate the VMs between sessions and delete the resource group when done;
// purge the vault afterwards or its name stays reserved by soft-delete.
//
// The same file builds the variations the verification needs: a second lab in another
// subscription (deployKeyVault=false, deployWindowsVm=false, nameSuffix=02) and a pair of CIS
// hardened marketplace images (windowsImage/linuxImage plus their plan, terms accepted first).
//
//   az deployment group create -g rg-crot-lab -f deploy/lab.bicep \
//     -p adminPassword=<generated> deployerObjectId=$(az ad signed-in-user show --query id -o tsv)
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Suffix on the VM names, so several labs can coexist: vm-crot-win-<suffix>, vm-crot-lnx-<suffix>.')
@minLength(1)
@maxLength(4)
param nameSuffix string = '01'

@description('VM size. Both images are Gen2. D2als_v6 is the cheapest size most subscriptions have quota for; B-series would do if yours allows it.')
param vmSize string = 'Standard_D2als_v6'

@description('Local administrator name on both machines. The rotation replaces its credentials.')
param adminUsername string = 'labadmin'

@secure()
@description('Initial local administrator password. Generated per deployment; the first rotation replaces it.')
param adminPassword string

@description('Create the Key Vault. Off for a second lab that shares the first one\'s vault.')
param deployKeyVault bool = true

@description('Object ID of whoever runs the lab, granted Key Vault Secrets Officer so the module can be run from a workstation. Required with deployKeyVault.')
param deployerObjectId string = ''

param deployWindowsVm bool = true
param deployLinuxVm bool = true

@description('Image reference for the Windows VM. Swap in a marketplace image such as a CIS hardened one, and set windowsPlan with it.')
param windowsImage object = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2022-datacenter-azure-edition'
  version: 'latest'
}

@description('Image reference for the Linux VM.')
param linuxImage object = {
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
}

@description('Marketplace plan for a third-party Windows image ({ name, product, publisher }); empty for first-party images. Accept the terms first: az vm image terms accept --publisher ... --offer ... --plan ...')
param windowsPlan object = {}

@description('Marketplace plan for a third-party Linux image; empty for first-party images.')
param linuxPlan object = {}

@description('VM tag the orchestrator looks for. Set on both machines so a runbook deployment finds them.')
param enableTagName string = 'CredentialRotation'
param enableTagValue string = 'enabled'

@description('Tags applied to every resource.')
param tags object = {
  Environment: 'lab'
  Owner: 'simon'
  CostCenter: 'lab'
  Project: 'azure-vm-credential-rotation'
}

var vmTags = union(tags, { '${enableTagName}': enableTagValue })
var windowsVmName = 'vm-crot-win-${nameSuffix}'
var linuxVmName = 'vm-crot-lnx-${nameSuffix}'

// Key Vault names are global, so the suffix keeps the lab redeployable in another subscription.
var keyVaultName = 'kv-crot-${uniqueString(resourceGroup().id)}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Key Vault Secrets Officer for the person running the lab.
resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployKeyVault) {
  name: guid(resourceGroup().id, keyVaultName, deployerObjectId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: deployerObjectId
    principalType: 'User'
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-crot-lab'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-crot-lab'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.43.0.0/24']
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'snet-vms'
  properties: {
    addressPrefix: '10.43.0.0/26'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource windowsNic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployWindowsVm) {
  name: 'nic-${windowsVmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource linuxNic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployLinuxVm) {
  name: 'nic-${linuxVmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource windowsVm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployWindowsVm) {
  name: windowsVmName
  location: location
  tags: vmTags
  plan: empty(windowsPlan) ? null : windowsPlan
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: windowsVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
        }
      }
    }
    storageProfile: {
      imageReference: windowsImage
      osDisk: {
        name: 'osdisk-${windowsVmName}'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: windowsNic!.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource linuxVm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployLinuxVm) {
  name: linuxVmName
  location: location
  tags: vmTags
  plan: empty(linuxPlan) ? null : linuxPlan
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: linuxVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        // On purpose: with password authentication on, the module rotates both the password and
        // the SSH key of this machine, which is the case the lab exists to cover.
        disablePasswordAuthentication: false
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'ImageDefault'
        }
      }
    }
    storageProfile: {
      imageReference: linuxImage
      osDisk: {
        name: 'osdisk-${linuxVmName}'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: linuxNic!.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output keyVaultName string = deployKeyVault ? keyVault!.name : ''
output windowsVmName string = deployWindowsVm ? windowsVm!.name : ''
output linuxVmName string = deployLinuxVm ? linuxVm!.name : ''
output adminUsername string = adminUsername
