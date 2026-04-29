// Linux jumpbox VM for operator access over Azure Bastion.
// - No public IP.
// - UAMI attached with AcrPush/AcrPull and Contributor (scoped RG) so scripts
//   1-3 can run end-to-end from inside the VNet.
// - cloud-init installs Azure CLI, Docker, Bicep.

@description('Location for the VM')
param location string = resourceGroup().location

@description('VM name')
param name string

@description('Subnet id for the VM NIC')
param subnetId string

@description('VM size. B-series default — cheap, enough for az cli + docker.')
param vmSize string = 'Standard_B2s'

@description('Admin username for SSH (accessed via Bastion)')
param adminUsername string = 'azureuser'

@description('SSH public key used to log in (via Bastion)')
@secure()
param adminPublicKey string

@description('User-assigned managed identity resource id to attach to the VM')
param userAssignedIdentityId string

@description('Tags for resources')
param tags object = {}

var cloudInit = '''
#cloud-config
package_update: true
package_upgrade: false
packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - jq
  - git
runcmd:
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  - az bicep install || true
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG docker azureuser
'''

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output nicPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
