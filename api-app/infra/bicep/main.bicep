@description('Name prefix for resources')
@minLength(4)
param namePrefix string = 'aiinvest'

@description('Environment name (dev, staging, prod)')
param environment string = 'dev'

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Container Registry login server, e.g. myacr.azurecr.io')
param containerRegistryServer string

@description('Container image for the backend app')
param containerImage string

@description('Cosmos DB account endpoint')
param cosmosAccountEndpoint string

@description('Cosmos DB database name')
param cosmosDbName string

@description('Storage Account name')
param storageAccountName string

@description('CORS allowed origins')
param allowOrigins string[] = ['*']

@description('When true, deploys the web app with public access disabled and a private endpoint.')
param isPrivate bool = true

@description('User Assigned Identity name (existing in same RG).')
param userAssignedIdentityName string

@description('Subnet ID for regional VNet integration (snet-services).')
param vnetIntegrationSubnetId string

@description('Subnet ID for the private endpoint (snet-pe).')
param privateEndpointSubnetId string

@description('Private DNS zone ID for privatelink.azurewebsites.net')
param appServicePrivateDnsZoneId string

@description('Additional environment variables')
param additionalEnvironmentVariables array = []

@description('Tags for resources')
param tags object = {}

var appName = '${namePrefix}-api-${environment}'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  scope: resourceGroup()
  name: userAssignedIdentityName
}

var environmentVariables = concat(
  [
    {
      name: 'COSMOS_DB_ENDPOINT'
      value: cosmosAccountEndpoint
    }
    {
      name: 'COSMOS_DB_DATABASE_NAME'
      value: cosmosDbName
    }
    {
      name: 'AZURE_STORAGE_ACCOUNT_NAME'
      value: storageAccountName
    }
    {
      name: 'AZURE_OPENAI_ENDPOINT'
      value: ''
    }
    {
      name: 'AZURE_OPENAI_DEPLOYMENT_NAME'
      value: ''
    }
    {
      name: 'ALLOW_ORIGINS'
      value: join(allowOrigins, ',')
    }
  ],
  additionalEnvironmentVariables
)

module apiApp '../../../infra/bicep/modules/web-app-container.bicep' = {
  name: 'apiAppDeployment'
  params: {
    name: appName
    location: resourceGroup().location
    tags: tags
    appServicePlanId: appServicePlanId
    containerImage: containerImage
    containerRegistryServer: containerRegistryServer
    userAssignedIdentityResourceId: userAssignedIdentity.id
    userAssignedIdentityClientId: userAssignedIdentity.properties.clientId
    targetPort: 8090
    healthCheckPath: '/health'
    isPrivate: isPrivate
    vnetIntegrationSubnetId: vnetIntegrationSubnetId
    privateEndpointSubnetId: privateEndpointSubnetId
    appServicePrivateDnsZoneId: appServicePrivateDnsZoneId
    appSettings: environmentVariables
  }
}

output containerAppName string = apiApp.outputs.name
output containerAppUrl string = apiApp.outputs.defaultHostName
output containerAppId string = apiApp.outputs.id
