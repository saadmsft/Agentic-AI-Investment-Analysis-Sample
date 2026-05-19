@description('Required: Name of the Container Registry')
param containerRegistryName string

@description('Optional: Location for all resources. Default is the resource group location')
param location string = resourceGroup().location

@description('Optional: Container Registry SKU. Default is Basic (switches to Premium automatically when isPrivate=true).')
param sku string = 'Basic'

@description('Optional: Admin user enabled. Default is true (forced off when isPrivate=true)')
param adminUserEnabled bool = true

@description('Public network access setting for the Azure Container Registry')
param publicNetworkAccess string = 'Enabled'

@description('Zone redundancy setting for the Azure Container Registry')
param zoneRedundancy string = 'Disabled'

@description('When true, forces Premium SKU + disables admin + public access and deploys a private endpoint.')
param isPrivate bool = false

@description('Subnet resource id for the private endpoint (required when isPrivate=true)')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource id for ACR (required when isPrivate=true)')
param acrPrivateDnsZoneId string = ''

@description('Managed Identity that will be given access to the Container Registry')
param roleAssignedManagedIdentityPrincipalIds string[]

@description('Optional: Tags for resources')
param tags object = {}

var roleAssignmentsAcrPull = [
    for principalId in roleAssignedManagedIdentityPrincipalIds: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'AcrPull'        
    }
  ]

var roleAssignmentsAcrPush = [
    for principalId in roleAssignedManagedIdentityPrincipalIds: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'AcrPush'        
    }
  ]

var roleAssignmentsAcrDelete = [
    for principalId in roleAssignedManagedIdentityPrincipalIds: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'AcrDelete'        
    }
  ]

var effectiveSku = isPrivate ? 'Premium' : sku
var effectiveAdmin = isPrivate ? false : adminUserEnabled
var effectivePublic = isPrivate ? 'Disabled' : publicNetworkAccess

// Use Azure Verified Module for Container Registry
module containerRegistry 'br:mcr.microsoft.com/bicep/avm/res/container-registry/registry:0.9.3' = {
  params: {
    name: containerRegistryName
    location: location
    tags: tags
    acrSku: effectiveSku
    acrAdminUserEnabled: effectiveAdmin
    publicNetworkAccess: effectivePublic
    zoneRedundancy: zoneRedundancy
    roleAssignments: concat(roleAssignmentsAcrPull, roleAssignmentsAcrPush, roleAssignmentsAcrDelete)
  }
}

// Output
output name string = containerRegistry.outputs.name
output loginServer string = containerRegistry.outputs.loginServer
output resourceGroupName string = containerRegistry.outputs.resourceGroupName
output resourceId string = containerRegistry.outputs.resourceId
output systemAssignedMIPrincipalId string? = containerRegistry.outputs.?systemAssignedMIPrincipalId
output credentialSetsSystemAssignedMIPrincipalIds array = containerRegistry.outputs.credentialSetsSystemAssignedMIPrincipalIds
output credentialSetsResourceIds array = containerRegistry.outputs.credentialSetsResourceIds
output privateEndpoints array = containerRegistry.outputs.privateEndpoints

resource acrRef 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
  dependsOn: [ containerRegistry ]
}

module pe 'private-endpoint.bicep' = if (isPrivate && !empty(privateEndpointSubnetId)) {
  name: 'acr-pe-${uniqueString(containerRegistryName)}'
  params: {
    name: '${containerRegistryName}-pe'
    location: location
    subnetId: privateEndpointSubnetId
    targetResourceId: acrRef.id
    groupIds: [ 'registry' ]
    privateDnsZoneIds: empty(acrPrivateDnsZoneId) ? [] : [ acrPrivateDnsZoneId ]
    tags: tags
  }
}
