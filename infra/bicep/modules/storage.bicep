@description('Optional: Location for all resources')
param location string = resourceGroup().location

@description('Required: Storage account name')
param storageAccountName string

@description('Managed Identity that will be given access to the Storage Account')
param roleAssignedManagedIdentityPrincipalIds string[]

@description('Optional: Name of the blob container for opportunity documents. Default is "opportunity-documents"')
param docsContainerName string = 'opportunity-documents'

@description('Optional: Tags for resources')
param tags object = {}

@description('When true, disables public network access and deploys a private endpoint for blob.')
param isPrivate bool = false

@description('Subnet resource id for the private endpoint (required when isPrivate=true)')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource id for blob (required when isPrivate=true)')
param blobPrivateDnsZoneId string = ''

var accountRoleAssignments array = [for principalId in roleAssignedManagedIdentityPrincipalIds: {
          principalId: principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Contributor'        
        }
      ]

var blobRoleAssignments array = [for principalId in roleAssignedManagedIdentityPrincipalIds: {
          principalId: principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Storage Blob Data Contributor'        
        }
      ]

var deployerRoleAssignments = [
    {
      principalId: deployer().objectId
      principalType: 'User'
      roleDefinitionIdOrName: 'Storage Blob Data Contributor'        
    }
    {
      principalId: deployer().objectId
      principalType: 'User'
      roleDefinitionIdOrName: 'Storage Queue Data Contributor'        
    }
  ]

// Use Azure Verified Module for Storage Account
module storageAccount 'br/public:avm/res/storage/storage-account:0.27.1' = {
  params: {
    // Required parameters
    name: storageAccountName
    // Non-required parameters
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    accessTier: 'Hot'
    allowSharedKeyAccess: false
    enableHierarchicalNamespace: false
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: isPrivate ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
    blobServices: {
      automaticSnapshotPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
      containerDeleteRetentionPolicyEnabled: true
      containers: [
        {
          name: docsContainerName
          publicAccess: 'None'
        }
      ]
    }
    roleAssignments: concat(
      accountRoleAssignments,
      blobRoleAssignments,
      deployerRoleAssignments
    )
    tags: tags
  }
}

output name string = storageAccount.outputs.name
output resourceId string = storageAccount.outputs.resourceId
output queueUrl string = 'https://${storageAccount.outputs.name}.queue.${environment().suffixes.storage}/'

resource storageAccountRef 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
  dependsOn: [ storageAccount ]
}

module pe 'private-endpoint.bicep' = if (isPrivate) {
  name: 'storage-pe-${uniqueString(storageAccountName)}'
  params: {
    name: '${storageAccountName}-pe-blob'
    location: location
    subnetId: privateEndpointSubnetId
    targetResourceId: storageAccountRef.id
    groupIds: [ 'blob' ]
    privateDnsZoneIds: empty(blobPrivateDnsZoneId) ? [] : [ blobPrivateDnsZoneId ]
    tags: tags
  }
}
