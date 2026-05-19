targetScope = 'resourceGroup' // Resource group scope

@description('Name prefix for all resources')
param namePrefix string = 'invstdemo'

@description('Environment name (dev, staging, prod)')
param environment string = 'dev'

@description('Location for all resources')
param location string = resourceGroup().location

// ################################################
// Zero-trust / networking parameters

@description('When true, deploys the zero-trust topology: VNet + private endpoints + private App Service + disabled public network access on all PaaS resources.')
param isPrivate bool = true

@description('Address space for the workload VNet. Customer supplies a /26 (e.g. 10.123.45.0/26). Required for both private and public deployments (a placeholder is acceptable when isPrivate=false).')
param vnetAddressPrefix string

@description('When true, deploys for the InvestCorp/IVC managed environment: keeps publicNetworkAccess=Disabled on all PaaS, but skips NSG creation, private DNS zones, and ALL private endpoints. The customer\'s network team creates NSGs, PEs, and DNS zone records out-of-band against their pre-existing hub-managed private DNS zones. Requires isPrivate=true.')
param investcorpEnv bool = false

// ################################################
// Application specific parameters

@description('Cosmos DB database name')
param cosmosDbName string = 'ai-investment-analysis-sample'

param cosmosDBContainerNames array = [
  { name: 'opportunities', partitionKey: '/owner_id' }
  { name: 'users', partitionKey: '/email' }
  { name: 'documents', partitionKey: '/opportunity_id' }
  { name: 'analysis', partitionKey: '/opportunity_id' }
  { name: 'workflow_events', partitionKey: '/analysis_id' }
  { name: 'what_if_conversations', partitionKey: '/analysis_id' }
]

@description('Name of the blob storage container for documents')
param docsContainerName string = 'opportunity-documents'

@description('Location for AI Foundry resources')
param aiFoundryLocation string = resourceGroup().location

// ################################################
// Optional explicit resource-name overrides.
// Leave any of these empty ('') to fall back to the default
// pattern `${namePrefix}-<kind>-${uniqueString(rg.id)}` shown next to each
// parameter. Customers that have their own naming convention (e.g. Cloud
// Adoption Framework / corporate standard) can supply the exact names here
// via parameters file. Names are not validated for Azure length/charset
// rules — the caller is responsible for picking a compliant name.

@description('Optional. Explicit name for the workload VNet. Default: <namePrefix>-vnet-<hash>')
param vnetNameOverride string = ''

@description('Optional. Explicit name for the User-Assigned Managed Identity. Default: <namePrefix>-uai-<hash>')
param userAssignedIdentityNameOverride string = ''

@description('Optional. Explicit name for the Log Analytics workspace. Default: <namePrefix>-law-<hash>')
param logAnalyticsWorkspaceNameOverride string = ''

@description('Optional. Explicit name for the Application Insights component. Default: <namePrefix>-appi-<hash>')
param appInsightsNameOverride string = ''

@description('Optional. Explicit name for the Azure Monitor Private Link Scope. Default: <namePrefix>-ampls-<hash>')
param amplsNameOverride string = ''

@description('Optional. Explicit name for the Storage account (must be 3-24 lowercase alphanumerics). Default: <namePrefix>sta<hash> trimmed to 24 chars')
param storageAccountNameOverride string = ''

@description('Optional. Explicit name for the Cosmos DB account. Default: <namePrefix>-cosmosdb-<hash>')
param cosmosAccountNameOverride string = ''

@description('Optional. Explicit name for the Azure Container Registry (must be 5-50 alphanumerics). Default: <namePrefix>acr<hash>')
param containerRegistryNameOverride string = ''

@description('Optional. Explicit name for the App Service Plan. Default: <namePrefix>-asp-<hash>')
param appServicePlanNameOverride string = ''

@description('Optional. Explicit base name (max 12 chars, lowercase) used to derive AI Foundry resource names. Default: derived from <namePrefix>-<environment>-<rg.id>')
param aiFoundryBaseNameOverride string = ''

@description('Optional. Explicit AI Foundry project name. Default: aiinvest-project')
param aiFoundryProjectNameOverride string = ''

var resourceGroupId = resourceGroup().id
var tags = {
  Environment: environment
  Project: 'ai-investment-analysis-sample'
}

var shortHash = substring(uniqueString(resourceGroup().id, deployment().name), 0, 8)

// Resolved resource names — use override when supplied, otherwise the
// default generator pattern.
var defaultStorageName = toLower('${namePrefix}sta${uniqueString(resourceGroupId)}')
var resolvedVnetName = empty(vnetNameOverride)
  ? toLower('${namePrefix}-vnet-${uniqueString(resourceGroupId)}')
  : vnetNameOverride
var resolvedUamiName = empty(userAssignedIdentityNameOverride)
  ? toLower('${namePrefix}-uai-${uniqueString(resourceGroupId)}')
  : userAssignedIdentityNameOverride
var resolvedLawName = empty(logAnalyticsWorkspaceNameOverride)
  ? toLower('${namePrefix}-law-${uniqueString(resourceGroupId)}')
  : logAnalyticsWorkspaceNameOverride
var resolvedAppiName = empty(appInsightsNameOverride)
  ? toLower('${namePrefix}-appi-${uniqueString(resourceGroupId)}')
  : appInsightsNameOverride
var resolvedAmplsName = empty(amplsNameOverride)
  ? toLower('${namePrefix}-ampls-${uniqueString(resourceGroupId)}')
  : amplsNameOverride
var resolvedStorageName = empty(storageAccountNameOverride)
  ? (length(defaultStorageName) > 24 ? substring(defaultStorageName, 0, 24) : defaultStorageName)
  : storageAccountNameOverride
var resolvedCosmosName = empty(cosmosAccountNameOverride)
  ? toLower('${namePrefix}-cosmosdb-${uniqueString(resourceGroup().id)}')
  : cosmosAccountNameOverride
var resolvedAcrName = empty(containerRegistryNameOverride)
  ? toLower('${namePrefix}acr${uniqueString(resourceGroupId)}')
  : containerRegistryNameOverride
var resolvedAspName = empty(appServicePlanNameOverride)
  ? toLower('${namePrefix}-asp-${uniqueString(resourceGroupId)}')
  : appServicePlanNameOverride
var resolvedAiFoundryBaseName = empty(aiFoundryBaseNameOverride)
  ? substring(toLower(uniqueString('ai-${namePrefix}-${environment}-${resourceGroup().id}')), 0, 12)
  : aiFoundryBaseNameOverride

// ################################################
// Networking (VNet + Private DNS) — deployed first when isPrivate=true

module network 'modules/network.bicep' = if (isPrivate) {
  name: 'networkDeployment.${shortHash}'
  params: {
    vnetName: resolvedVnetName
    vnetAddressPrefix: vnetAddressPrefix
    location: location
    tags: tags
    deployNetworkSecurityGroups: !investcorpEnv
  }
}

module privateDns 'modules/private-dns.bicep' = if (isPrivate && !investcorpEnv) {
  name: 'privateDnsDeployment.${shortHash}'
  params: {
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

// ################################################
// Identity

module userAssignedIdentity 'modules/user-assigned-identity.bicep' = {
  name: 'userAssignedIdentityDeployment.${shortHash}'
  params: {
    userAssignedIdentityName: resolvedUamiName
    location: location
    tags: tags
  }
}

// ################################################
// Log Analytics + Application Insights

module logAnalytics 'modules/log-analytics-ws.bicep' = {
  name: 'logAnalyticsDeployment.${shortHash}'
  params: {
    logAnalyticsWorkspaceName: resolvedLawName
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    location: location
    tags: tags
    isPrivate: isPrivate
  }
}

module appInsights 'modules/app-insights.bicep' = {
  name: 'appInsightsDeployment.${shortHash}'
  params: {
    appInsightsName: resolvedAppiName
    location: location
    logAnalyticsResourceId: logAnalytics.outputs.resourceId
    tags: tags
    isPrivate: isPrivate
  }
}

// Azure Monitor Private Link Scope — binds LA + AppI so telemetry flows over VNet.
// In investcorpEnv mode the AMPLS resource itself is still created (customer
// asked for it with their naming convention), but its private endpoint is
// skipped — the IVC network team adds the PE manually against their
// pre-existing private DNS zones.
module ampls 'modules/ampls.bicep' = if (isPrivate) {
  name: 'amplsDeployment.${shortHash}'
  params: {
    name: resolvedAmplsName
    logAnalyticsResourceId: logAnalytics.outputs.resourceId
    appInsightsResourceId: appInsights.outputs.resourceId
    privateEndpointSubnetId: investcorpEnv ? '' : network.outputs.peSubnetId
    privateEndpointLocation: location
    privateDnsZoneIds: investcorpEnv ? [] : [
      privateDns.outputs.monitorZoneId
      privateDns.outputs.omsZoneId
      privateDns.outputs.odsZoneId
      privateDns.outputs.agentsvcZoneId
      privateDns.outputs.blobFixedZoneId
    ]
    tags: tags
  }
}

// ################################################
// Storage

module storage 'modules/storage.bicep' = {
  name: 'storageAccountDeployment.${shortHash}'
  params: {
    storageAccountName: resolvedStorageName
    location: location
    docsContainerName: docsContainerName
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    tags: tags
    isPrivate: isPrivate
    investcorpEnv: investcorpEnv
    privateEndpointSubnetId: (isPrivate && !investcorpEnv) ? network.outputs.peSubnetId : ''
    blobPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.blobZoneStorageSuffixId : ''
  }
}

// ################################################
// Cosmos DB

module cosmosDb 'modules/cosmos-db.bicep' = {
  name: 'cosmosDbDeployment.${shortHash}'
  params: {
    location: location
    cosmosAccountName: resolvedCosmosName
    cosmosDbName: cosmosDbName
    cosmosDBContainerNames: cosmosDBContainerNames
    cosmosDBDataContributorPrincipalIds: [userAssignedIdentity.outputs.principalId, deployer().objectId]
    zoneRedundant: environment == 'prod' ? true : false
    tags: tags
    isPrivate: isPrivate
    privateEndpointSubnetId: (isPrivate && !investcorpEnv) ? network.outputs.peSubnetId : ''
    cosmosSqlPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.cosmosSqlZoneId : ''
  }
}

// ################################################
// Container Registry

module containerRegistry 'modules/container-registry.bicep' = {
  name: 'containerRegistryDeployment.${shortHash}'
  params: {
    containerRegistryName: resolvedAcrName
    location: location
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    tags: tags
    isPrivate: isPrivate
    privateEndpointSubnetId: (isPrivate && !investcorpEnv) ? network.outputs.peSubnetId : ''
    acrPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.acrZoneId : ''
  }
}

// ################################################
// Compute host: App Service Plan (Linux) — replaces ACA env.
// Web Apps for Containers are deployed by api-app/web-app templates and
// are bound to this plan. Private endpoint + VNet integration are wired
// per-app inside web-app-container.bicep.

module appServicePlan 'modules/app-service-plan.bicep' = {
  name: 'appServicePlanDeployment.${shortHash}'
  params: {
    name: resolvedAspName
    location: location
    tags: tags
  }
}

// NOTE: ACA env module has been retired in favor of App Service.
// modules/container-apps-environment.bicep is kept on disk for reference
// but is no longer instantiated.

// ################################################
// AI Foundry

module aiFoundry 'modules/ai-foundry.bicep' = {
  name: 'aiFoundryDeployment.${shortHash}'
  params: {
    aiFoundryBaseName: resolvedAiFoundryBaseName
    aiFoundryProjectName: empty(aiFoundryProjectNameOverride) ? 'aiinvest-project' : aiFoundryProjectNameOverride
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    location: aiFoundryLocation
    tags: tags
    isPrivate: isPrivate
    skipPrivateEndpoints: investcorpEnv
    openAiPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.openAiZoneId : ''
    cognitiveServicesPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.cognitiveServicesZoneId : ''
    aiServicesPrivateDnsZoneId: (isPrivate && !investcorpEnv) ? privateDns.outputs.aiServicesZoneId : ''
  }
}

// ################################################
// Outputs

output userAssignedIdentityName string = userAssignedIdentity.outputs.name
output userAssignedIdentityPrincipalId string = userAssignedIdentity.outputs.principalId
output userAssignedIdentityResourceId string = userAssignedIdentity.outputs.resourceId
output userAssignedIdentityClientId string = userAssignedIdentity.outputs.clientId
output containerRegistryName string = containerRegistry.outputs.name
output containerRegistryLoginServer string = containerRegistry.outputs.loginServer
output appServicePlanId string = appServicePlan.outputs.id
output appServicePlanName string = appServicePlan.outputs.name
output appSvcSubnetId string = isPrivate ? network.outputs.appSvcSubnetId : ''
output peSubnetId string = isPrivate ? network.outputs.peSubnetId : ''
output appServicePrivateDnsZoneId string = (isPrivate && !investcorpEnv) ? privateDns.outputs.appServiceZoneId : ''
output investcorpEnv bool = investcorpEnv
output storageAccountName string = storage.outputs.name
output cosmosAccountName string = cosmosDb.outputs.cosmosAccountName
output cosmosEndpoint string = cosmosDb.outputs.cosmosEndpoint
output cosmosDBName string = cosmosDb.outputs.cosmosDBName
output aiProjectName string = aiFoundry.outputs.aiProjectName
output aiServicesName string = aiFoundry.outputs.aiServicesName
output isPrivate bool = isPrivate
output vnetId string = isPrivate ? network.outputs.vnetId : ''
