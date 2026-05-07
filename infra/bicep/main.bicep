targetScope = 'resourceGroup' // Resource group scope

@description('Name prefix for all resources')
param namePrefix string = 'invstdemo'

@description('Environment name (dev, staging, prod)')
param environment string = 'dev'

@description('Location for all resources')
param location string = resourceGroup().location

// ################################################
// Zero-trust / networking parameters

@description('When true, deploys the zero-trust topology: VNet + private endpoints + internal ACA + disabled public network access on all PaaS resources.')
param isPrivate bool = true

@description('When true (and isPrivate=true), also deploys a Windows jumpbox + Azure Bastion for operator access.')
param deployJumpbox bool = true

@description('VNet address space used when isPrivate=true')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Admin username for the jumpbox VM')
param jumpboxAdminUsername string = 'azureuser'

@description('Admin password for the Windows jumpbox VM (required when deployJumpbox=true). Must satisfy Azure Windows VM password complexity rules: 12-123 chars; 3 of: lowercase, uppercase, digit, special.')
@secure()
param jumpboxAdminPassword string = ''

@description('Azure Bastion SKU. Standard required for native-client tunneling.')
@allowed([ 'Basic', 'Standard' ])
param bastionSku string = 'Standard'

// ################################################
// Application specific parameters

@description('Cosmos DB database name')
param cosmosDbName string = 'ai-investment-analysis-sample'

param cosmosDBContainerNames array = [
  {name: 'opportunities', partitionKey: '/owner_id'}
  {name: 'users', partitionKey: '/email'}
  {name: 'documents', partitionKey: '/opportunity_id'}
  {name: 'analysis', partitionKey: '/opportunity_id'}
  {name: 'workflow_events', partitionKey: '/analysis_id'}
  {name: 'what_if_conversations', partitionKey: '/analysis_id'}
]

@description('Name of the blob storage container for documents')
param docsContainerName string = 'opportunity-documents'

@description('Location for AI Foundry resources')
param aiFoundryLocation string = resourceGroup().location


var resourceGroupId = resourceGroup().id
var tags = {
  Environment: environment
  Project: 'ai-investment-analysis-sample'
}

var shortHash = substring(uniqueString(resourceGroup().id, deployment().name), 0, 8)

// ################################################
// Networking (VNet + Private DNS) — deployed first when isPrivate=true

module network 'modules/network.bicep' = if (isPrivate) {
  name: 'networkDeployment.${shortHash}'
  params: {
    vnetName: toLower('${namePrefix}-vnet-${uniqueString(resourceGroupId)}')
    vnetAddressPrefix: vnetAddressPrefix
    location: location
    tags: tags
  }
}

module privateDns 'modules/private-dns.bicep' = if (isPrivate) {
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
    userAssignedIdentityName: toLower('${namePrefix}-uai-${uniqueString(resourceGroupId)}')
    location: location
    tags: tags
  }
}

// ################################################
// Log Analytics + Application Insights

module logAnalytics 'modules/log-analytics-ws.bicep' = {
  name: 'logAnalyticsDeployment.${shortHash}'
  params: {
    logAnalyticsWorkspaceName: toLower('${namePrefix}-law-${uniqueString(resourceGroupId)}')
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    location: location
    tags: tags
    isPrivate: isPrivate
  }
}

module appInsights 'modules/app-insights.bicep' = {
  name: 'appInsightsDeployment.${shortHash}'
  params: {
    appInsightsName: toLower('${namePrefix}-appi-${uniqueString(resourceGroupId)}')
    location: location
    logAnalyticsResourceId: logAnalytics.outputs.resourceId
    tags: tags
    isPrivate: isPrivate
  }
}

// Azure Monitor Private Link Scope — binds LA + AppI so telemetry flows over VNet.
module ampls 'modules/ampls.bicep' = if (isPrivate) {
  name: 'amplsDeployment.${shortHash}'
  params: {
    name: toLower('${namePrefix}-ampls-${uniqueString(resourceGroupId)}')
    logAnalyticsResourceId: logAnalytics.outputs.resourceId
    appInsightsResourceId: appInsights.outputs.resourceId
    privateEndpointSubnetId: network.outputs.peSubnetId
    privateEndpointLocation: location
    privateDnsZoneIds: [
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
    storageAccountName: length('${namePrefix}sta${uniqueString(resourceGroupId)}') > 24 ? substring(toLower('${namePrefix}sta${uniqueString(resourceGroupId)}'), 0, 24) : toLower('${namePrefix}sta${uniqueString(resourceGroupId)}')
    location: location
    docsContainerName: docsContainerName
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    tags: tags
    isPrivate: isPrivate
    privateEndpointSubnetId: isPrivate ? network.outputs.peSubnetId : ''
    blobPrivateDnsZoneId: isPrivate ? privateDns.outputs.blobZoneStorageSuffixId : ''
  }
}

// ################################################
// Cosmos DB

module cosmosDb 'modules/cosmos-db.bicep' = {
  name: 'cosmosDbDeployment.${shortHash}'
  params: {
    location: location
    cosmosAccountName: toLower('${namePrefix}-cosmosdb-${uniqueString(resourceGroup().id)}')
    cosmosDbName: cosmosDbName
    cosmosDBContainerNames: cosmosDBContainerNames
    cosmosDBDataContributorPrincipalIds: [userAssignedIdentity.outputs.principalId, deployer().objectId]
    zoneRedundant: environment == 'prod' ? true : false
    tags: tags
    isPrivate: isPrivate
    privateEndpointSubnetId: isPrivate ? network.outputs.peSubnetId : ''
    cosmosSqlPrivateDnsZoneId: isPrivate ? privateDns.outputs.cosmosSqlZoneId : ''
  }
}

// ################################################
// Container Registry

module containerRegistry 'modules/container-registry.bicep' = {
  name: 'containerRegistryDeployment.${shortHash}'
  params: {
    containerRegistryName: toLower('${namePrefix}acr${uniqueString(resourceGroupId)}')
    location: location
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    tags: tags
    isPrivate: isPrivate
    privateEndpointSubnetId: isPrivate ? network.outputs.peSubnetId : ''
    acrPrivateDnsZoneId: isPrivate ? privateDns.outputs.acrZoneId : ''
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
    name: toLower('${namePrefix}-asp-${uniqueString(resourceGroupId)}')
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
    aiFoundryBaseName: substring(toLower(uniqueString('ai-${namePrefix}-${environment}-${resourceGroup().id}')), 0, 12)
    roleAssignedManagedIdentityPrincipalIds: [userAssignedIdentity.outputs.principalId]
    location: aiFoundryLocation
    tags: tags
    isPrivate: isPrivate
    openAiPrivateDnsZoneId: isPrivate ? privateDns.outputs.openAiZoneId : ''
    cognitiveServicesPrivateDnsZoneId: isPrivate ? privateDns.outputs.cognitiveServicesZoneId : ''
    aiServicesPrivateDnsZoneId: isPrivate ? privateDns.outputs.aiServicesZoneId : ''
  }
}

// ################################################
// Operator access plane — Bastion + Jumpbox

module bastion 'modules/bastion.bicep' = if (isPrivate && deployJumpbox) {
  name: 'bastionDeployment.${shortHash}'
  params: {
    name: toLower('${namePrefix}-bastion-${uniqueString(resourceGroupId)}')
    location: location
    subnetId: network.outputs.bastionSubnetId
    sku: bastionSku
    tags: tags
  }
}

module jumpbox 'modules/jumpbox.bicep' = if (isPrivate && deployJumpbox) {
  name: 'jumpboxDeployment.${shortHash}'
  params: {
    name: toLower('${namePrefix}-jump-${uniqueString(resourceGroupId)}')
    location: location
    subnetId: network.outputs.jumpboxSubnetId
    adminUsername: jumpboxAdminUsername
    adminPassword: jumpboxAdminPassword
    userAssignedIdentityId: userAssignedIdentity.outputs.resourceId
    tags: tags
  }
}

var uaiName = toLower('${namePrefix}-uai-${uniqueString(resourceGroupId)}')

// Grant the jumpbox identity the roles needed to run scripts end-to-end.
// UAMI already has AcrPull/AcrPush/AcrDelete + Storage + Cosmos data roles;
// add Contributor scoped to the resource group so it can deploy container apps.
resource jumpboxRgContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (isPrivate && deployJumpbox) {
  name: guid(resourceGroup().id, uaiName, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  scope: resourceGroup()
  properties: {
    principalId: userAssignedIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
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
output appServicePrivateDnsZoneId string = isPrivate ? privateDns.outputs.appServiceZoneId : ''
output storageAccountName string = storage.outputs.name
output cosmosAccountName string = cosmosDb.outputs.cosmosAccountName
output cosmosEndpoint string = cosmosDb.outputs.cosmosEndpoint
output cosmosDBName string = cosmosDb.outputs.cosmosDBName
output aiProjectName string = aiFoundry.outputs.aiProjectName
output aiServicesName string = aiFoundry.outputs.aiServicesName
output isPrivate bool = isPrivate
output vnetId string = isPrivate ? network.outputs.vnetId : ''
output jumpboxName string = (isPrivate && deployJumpbox) ? jumpbox.outputs.vmName : ''
output bastionName string = (isPrivate && deployJumpbox) ? bastion.outputs.bastionName : ''
