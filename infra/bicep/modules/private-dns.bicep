// Private DNS zones required by zero-trust architecture.
// One zone per service group; each zone is linked to the workload VNet so the
// the App Service apps and any peered operator hosts resolve private-endpoint IPs from the VNet.

@description('Name of the VNet to link zones to')
param vnetId string

@description('Location (zones are global; required for vnet-links).')
param location string = 'global'

@description('Tags for resources')
param tags object = {}

var zoneNames = [
  // Cosmos DB SQL API
  'privatelink.documents.azure.com'
  // Storage — blob (add file/queue/table only if you use them)
  'privatelink.blob.${environment().suffixes.storage}'
  // Azure Container Registry
  'privatelink.azurecr.io'
  // Azure AI services (OpenAI + Cognitive Services + Foundry services)
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.services.ai.azure.com'
  // App Configuration (used when enabled)
  'privatelink.azconfig.io'
  // Azure Monitor Private Link Scope (AMPLS) — reuses the storage blob zone
  // above for AMPLS's blob link, so do NOT redeclare it here.
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  // App Service / Web App private endpoints
  'privatelink.azurewebsites.net'
]

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for z in zoneNames: {
    name: z
    location: location
    tags: tags
  }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in zoneNames: {
    name: '${zones[i].name}/link-${uniqueString(vnetId)}'
    location: location
    tags: tags
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
    dependsOn: [zones[i]]
  }
]

// Keyed outputs so the main template can wire each PE to its zone.
output cosmosSqlZoneId string = zones[0].id
output blobZoneStorageSuffixId string = zones[1].id
output acrZoneId string = zones[2].id
output openAiZoneId string = zones[3].id
output cognitiveServicesZoneId string = zones[4].id
output aiServicesZoneId string = zones[5].id
output appConfigZoneId string = zones[6].id
output monitorZoneId string = zones[7].id
output omsZoneId string = zones[8].id
output odsZoneId string = zones[9].id
output agentsvcZoneId string = zones[10].id
output appServiceZoneId string = zones[11].id
// AMPLS blob link reuses the storage blob zone to avoid duplicate zone.
output blobFixedZoneId string = zones[1].id
