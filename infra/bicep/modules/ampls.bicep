// Azure Monitor Private Link Scope (AMPLS) — binds App Insights + Log Analytics
// so telemetry flows over the VNet via private endpoint instead of public ingest.

@description('Location (AMPLS is a global resource; use global)')
param location string = 'global'

@description('AMPLS resource name')
param name string

@description('Log Analytics Workspace resource id to scope')
param logAnalyticsResourceId string

@description('Application Insights component resource id to scope')
param appInsightsResourceId string

@description('Subnet resource id where the PE NIC is placed. Leave empty to skip PE creation (customer-managed PE).')
param privateEndpointSubnetId string = ''

@description('Resource group location for the private endpoint resource')
param privateEndpointLocation string = resourceGroup().location

@description('Private DNS zone resource ids for Azure Monitor PLS (monitor, oms, ods, agentsvc, blob). Leave empty when skipping PE.')
param privateDnsZoneIds string[] = []

@description('Tags for resources')
param tags object = {}

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

resource lawScope 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'law-scope'
  properties: {
    linkedResourceId: logAnalyticsResourceId
  }
}

resource appiScope 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'appi-scope'
  properties: {
    linkedResourceId: appInsightsResourceId
  }
}

module ampPe 'private-endpoint.bicep' = if (!empty(privateEndpointSubnetId)) {
  name: 'ampls-pe-${uniqueString(ampls.id)}'
  params: {
    name: '${name}-pe'
    location: privateEndpointLocation
    subnetId: privateEndpointSubnetId
    targetResourceId: ampls.id
    groupIds: [ 'azuremonitor' ]
    privateDnsZoneIds: privateDnsZoneIds
    tags: tags
  }
  dependsOn: [ lawScope, appiScope ]
}

output amplsId string = ampls.id
output amplsName string = ampls.name
