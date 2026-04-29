// Linux Web App for Containers with:
//   * UAMI for ACR pull
//   * Regional VNet integration (outbound) into snet-appsvc
//   * Private endpoint in snet-pe (inbound) when isPrivate=true
//   * publicNetworkAccess=Disabled when isPrivate=true
//
// Container image is pulled from ACR using the supplied user-assigned identity.

@description('Web App name')
param name string

@description('Location for resources')
param location string = resourceGroup().location

@description('Tags for resources')
param tags object = {}

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Container image reference, e.g. myacr.azurecr.io/ai-invest-api:latest')
param containerImage string

@description('Container registry login server, e.g. myacr.azurecr.io')
param containerRegistryServer string

@description('User-assigned managed identity resource ID for ACR pull and runtime auth.')
param userAssignedIdentityResourceId string

@description('Client ID of the user-assigned identity (exposed to the app as AZURE_CLIENT_ID).')
param userAssignedIdentityClientId string

@description('Container target port the app listens on (set as WEBSITES_PORT)')
param targetPort int = 8090

@description('Subnet resource ID for regional VNet integration (Microsoft.Web/serverFarms delegation).')
param vnetIntegrationSubnetId string = ''

@description('When true, locks the app down: publicNetworkAccess=Disabled and creates a private endpoint.')
param isPrivate bool = true

@description('Subnet resource ID for the private endpoint (only when isPrivate=true).')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for privatelink.azurewebsites.net (only when isPrivate=true).')
param appServicePrivateDnsZoneId string = ''

@description('Additional app settings (array of {name,value}).')
param appSettings array = []

@description('Health check path (e.g. /health, /). Empty disables health check.')
param healthCheckPath string = ''

var baseAppSettings = [
  {
    name: 'WEBSITES_PORT'
    value: string(targetPort)
  }
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_URL'
    value: 'https://${containerRegistryServer}'
  }
  {
    name: 'DOCKER_ENABLE_CI'
    value: 'true'
  }
  {
    name: 'AZURE_CLIENT_ID'
    value: userAssignedIdentityClientId
  }
]

// When VNet-integrated, we want all outbound traffic (including DNS lookups
// to private endpoints) to traverse the integrated VNet so private DNS zones
// resolve correctly.
var vnetRouteAppSettings = empty(vnetIntegrationSubnetId) ? [] : [
  {
    name: 'WEBSITE_VNET_ROUTE_ALL'
    value: '1'
  }
  {
    name: 'WEBSITE_DNS_SERVER'
    value: '168.63.129.16'
  }
  {
    // Pull container image from ACR through the integrated VNet so that
    // private-endpoint-only registries (publicNetworkAccess=Disabled) work.
    name: 'WEBSITE_PULL_IMAGE_OVER_VNET'
    value: 'true'
  }
]

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'app,linux,container'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    keyVaultReferenceIdentity: userAssignedIdentityResourceId
    virtualNetworkSubnetId: empty(vnetIntegrationSubnetId) ? null : vnetIntegrationSubnetId
    vnetRouteAllEnabled: !empty(vnetIntegrationSubnetId)
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerImage}'
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: userAssignedIdentityClientId
      alwaysOn: true
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      healthCheckPath: empty(healthCheckPath) ? null : healthCheckPath
      appSettings: concat(baseAppSettings, vnetRouteAppSettings, appSettings)
    }
  }
}

// Private endpoint for inbound traffic (only when isPrivate=true).
resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = if (isPrivate) {
  name: '${name}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-pe-conn'
        properties: {
          privateLinkServiceId: site.id
          groupIds: [ 'sites' ]
        }
      }
    ]
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (isPrivate) {
  name: 'default'
  parent: pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'azurewebsites'
        properties: {
          privateDnsZoneId: appServicePrivateDnsZoneId
        }
      }
    ]
  }
}

output id string = site.id
output name string = site.name
output defaultHostName string = site.properties.defaultHostName
