@description('Location for all resources')
param location string = resourceGroup().location

@description('App Configuration Store name')
param appConfigStoreName string

@description('Managed Identity that will be given access to the App Configuration Store')
param roleAssignedManagedIdentityPrincipalIds string[]

@description('Key-Value pairs to initialize in the App Configuration Store')
param configurationKeyValues array = []

@description('Tags for resources')
param tags object = {}

@description('When true, disables public network access + local auth and deploys a private endpoint.')
param isPrivate bool = false

@description('Subnet resource id for the private endpoint (required when isPrivate=true)')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource id for App Configuration (required when isPrivate=true)')
param appConfigPrivateDnsZoneId string = ''

// Create list of role assignments for the managed identities
var roleAssignments = [
    for principalId in roleAssignedManagedIdentityPrincipalIds: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'App Configuration Data Reader'        
    }
  ]

var deployerRoleAssignments = [
    {
      principalId: deployer().objectId
      principalType: 'User'
      roleDefinitionIdOrName: 'App Configuration Data Owner'        
    }
  ]

// Use Azure Verified Module for Config Store
module configurationStore 'br/public:avm/res/app-configuration/configuration-store:0.9.2' = {
  params: {
    // Required parameters
    name: appConfigStoreName
    // Non-required parameters
    location: location
    tags: tags
    sku: 'Standard'
    createMode: 'Default'
    disableLocalAuth: isPrivate
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    enablePurgeProtection: false
    keyValues: [
      for config in configurationKeyValues: {
        contentType: config.contentType
        name: config.name
        value: config.value
      }
    ]
    softDeleteRetentionInDays: 1
    roleAssignments: concat(roleAssignments, deployerRoleAssignments)
  }
}

output endpoint string = configurationStore.outputs.endpoint
output resourceId string = configurationStore.outputs.resourceId
output name string = configurationStore.outputs.name

resource acsRef 'Microsoft.AppConfiguration/configurationStores@2023-03-01' existing = {
  name: appConfigStoreName
  dependsOn: [ configurationStore ]
}

module pe 'private-endpoint.bicep' = if (isPrivate) {
  name: 'acs-pe-${uniqueString(appConfigStoreName)}'
  params: {
    name: '${appConfigStoreName}-pe'
    location: location
    subnetId: privateEndpointSubnetId
    targetResourceId: acsRef.id
    groupIds: [ 'configurationStores' ]
    privateDnsZoneIds: empty(appConfigPrivateDnsZoneId) ? [] : [ appConfigPrivateDnsZoneId ]
    tags: tags
  }
}
