// Azure Bastion (Standard SKU) — the only public-facing TLS endpoint in the
// design. Users open a browser session to the bastion and SSH to the jumpbox.

@description('Location for the bastion host')
param location string = resourceGroup().location

@description('Bastion host name')
param name string

@description('AzureBastionSubnet resource id')
param subnetId string

@description('SKU: Basic or Standard. Standard required for native-client / SSH tunneling.')
@allowed([ 'Basic', 'Standard' ])
param sku string = 'Standard'

@description('Tags for resources')
param tags object = {}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${name}-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  properties: {
    enableTunneling: sku == 'Standard' ? true : false
    enableShareableLink: false
    ipConfigurations: [
      {
        name: 'ipConfig'
        properties: {
          subnet: { id: subnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
output publicIpAddress string = pip.properties.ipAddress
