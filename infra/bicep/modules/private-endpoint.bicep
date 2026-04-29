// Reusable Private Endpoint + Private DNS Zone Group module.
// Creates one Microsoft.Network/privateEndpoints resource targeting an
// existing PaaS resource, and registers its IP in the given private DNS zones.

@description('Location for the private endpoint')
param location string = resourceGroup().location

@description('Name of the private endpoint')
param name string

@description('Subnet resource id where the PE NIC is placed')
param subnetId string

@description('Resource id of the target PaaS resource')
param targetResourceId string

@description('groupIds for the PLS (e.g. Sql, blob, registry, account, azuremonitor, configurationStores)')
param groupIds string[]

@description('Array of private DNS zone resource ids to register the PE in')
param privateDnsZoneIds string[] = []

@description('Tags for resources')
param tags object = {}

resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (!empty(privateDnsZoneIds)) {
  name: 'default'
  parent: pe
  properties: {
    privateDnsZoneConfigs: [for (zoneId, i) in privateDnsZoneIds: {
      name: 'config${i}'
      properties: { privateDnsZoneId: zoneId }
    }]
  }
}

output peId string = pe.id
output peName string = pe.name
