// A fleet of small Linux VMs, for measuring how the rotation behaves at size.
//
// The question this answers is not "does it work" - lab.bicep covers that - but "how many
// machines fit in one run". Azure Automation unloads a job after three hours, and the rotation
// is sequential, so the honest way to state a limit is to measure the per-machine cost and
// divide. tests/manual/Measure-RotationThroughput.ps1 does the measuring.
//
// Deliberately the cheapest thing that still exercises the real path: Ubuntu with password
// authentication on, so every machine carries two credentials, no public IP, one vnet, and the
// sizes spread across families because a subscription's quota is per family. Delete the resource
// group when the numbers are in.
//
//   az deployment group create -g rg-crot-scale -f deploy/lab-scale.bicep \
//     -p adminPassword=<generated> vmCount=20
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('How many machines to build. Watch the total regional core quota, which is usually the binding one and is easy to mistake for the per-family limit: 2 vCPU each, so a region granted 14 cores holds seven of these.')
@minValue(1)
@maxValue(60)
param vmCount int = 6

@description('Name prefix, so a fleet spread over several regions does not collide. Secret names are derived from VM names, and two machines with the same name would share one secret in the vault.')
@minLength(1)
@maxLength(12)
param namePrefix string = 'vm-crot-s'

@description('Sizes to spread across, because core quota is granted per family. All 2 vCPU, all Gen2, all among the cheapest available.')
param vmSizes array = [
  'Standard_D2als_v6'
  'Standard_D2als_v7'
  'Standard_D2alds_v6'
  'Standard_D2lds_v6'
]

@description('Local administrator name. The rotation replaces its credentials.')
param adminUsername string = 'labadmin'

@secure()
@description('Initial local administrator password, replaced by the first rotation.')
param adminPassword string

@description('VM tag the orchestrator looks for.')
param enableTagName string = 'CredentialRotation'
param enableTagValue string = 'enabled'

param tags object = {
  Environment: 'lab'
  Owner: 'simon'
  CostCenter: 'lab'
  Project: 'azure-vm-credential-rotation'
}

var vmTags = union(tags, { '${enableTagName}': enableTagValue })

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  tags: tags
  properties: {
    // /22 so the subnet has room for the largest vmCount this template allows.
    addressSpace: {
      addressPrefixes: ['10.44.0.0/22']
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'snet-vms'
  properties: {
    addressPrefix: '10.44.0.0/22'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for i in range(0, vmCount): {
    name: 'nic-${namePrefix}${padLeft(i, 2, '0')}'
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
]

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for i in range(0, vmCount): {
    name: '${namePrefix}${padLeft(i, 2, '0')}'
    location: location
    tags: vmTags
    properties: {
      hardwareProfile: {
        vmSize: vmSizes[i % length(vmSizes)]
      }
      osProfile: {
        computerName: '${namePrefix}${padLeft(i, 2, '0')}'
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: {
          // Password authentication on, so each machine carries two credentials and the
          // measurement covers the SSH key path as well.
          disablePasswordAuthentication: false
          provisionVMAgent: true
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: 'ubuntu-24_04-lts'
          sku: 'server'
          version: 'latest'
        }
        osDisk: {
          name: 'osdisk-${namePrefix}${padLeft(i, 2, '0')}'
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
            id: nic[i].id
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
]

output vmNames array = [for i in range(0, vmCount): '${namePrefix}${padLeft(i, 2, '0')}']
