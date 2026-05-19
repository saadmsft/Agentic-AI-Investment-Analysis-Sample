@description('Name prefix for frontend resources')
param namePrefix string = 'aiinvest'

@description('Environment name (dev, staging, prod)')
param environment string = 'dev'

@description('Container registry server')
param containerRegistryServer string

@description('Container image')
param containerImage string

@description('When true, deploys the web app with public access disabled and a private endpoint.')
param isPrivate bool = true

@description('Backend API URL for frontend configuration')
param backendApiUrl string = ''

@description('App Service Plan resource ID')
param appServicePlanId string

@description('User Assigned Identity name (existing in same RG).')
param userAssignedIdentityName string

@description('Subnet ID for regional VNet integration (snet-services).')
param vnetIntegrationSubnetId string

@description('Subnet ID for the private endpoint (snet-pe).')
param privateEndpointSubnetId string

@description('Private DNS zone ID for privatelink.azurewebsites.net. Leave empty to skip the PE DNS zone group (customer-managed DNS).')
param appServicePrivateDnsZoneId string = ''

@description('Tags for resources')
param tags object = {
  Environment: environment
  Project: 'ai-investment-analysis-sample'
  Component: 'web app'
}

@description('Optional. Explicit App Service name override. Default: <namePrefix>-web-<environment>')
param appNameOverride string = ''

var appName = empty(appNameOverride) ? '${namePrefix}-web-${environment}' : appNameOverride

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  scope: resourceGroup()
  name: userAssignedIdentityName
}

var environmentVariables = !empty(backendApiUrl)
  ? [
      {
        name: 'VITE_API_BASE_URL'
        value: backendApiUrl
      }
    ]
  : []

module webApp '../../../infra/bicep/modules/web-app-container.bicep' = {
  name: 'webAppDeployment'
  params: {
    name: appName
    location: resourceGroup().location
    tags: tags
    appServicePlanId: appServicePlanId
    containerImage: containerImage
    containerRegistryServer: containerRegistryServer
    userAssignedIdentityResourceId: userAssignedIdentity.id
    userAssignedIdentityClientId: userAssignedIdentity.properties.clientId
    targetPort: 8080
    healthCheckPath: '/'
    isPrivate: isPrivate
    vnetIntegrationSubnetId: vnetIntegrationSubnetId
    privateEndpointSubnetId: privateEndpointSubnetId
    appServicePrivateDnsZoneId: appServicePrivateDnsZoneId
    appSettings: environmentVariables
  }
}

output containerAppName string = webApp.outputs.name
output containerAppUrl string = webApp.outputs.defaultHostName
output containerAppId string = webApp.outputs.id
