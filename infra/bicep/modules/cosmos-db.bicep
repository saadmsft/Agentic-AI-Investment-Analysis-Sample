@description('Optional: Location for all resources')
param location string = resourceGroup().location

@description('Required: Cosmos DB account name')
param cosmosAccountName string

@description('Required: Cosmos DB database name')
param cosmosDbName string

@description('Optional: Cosmos DB container names used in the application')
param cosmosDBContainerNames array

@description('Required: List of principal IDs (managed identity or user) to be assigned Cosmos DB SQL Data Contributor role')
param cosmosDBDataContributorPrincipalIds string[]

@description('Enable zone redundancy for Cosmos DB account')
param zoneRedundant bool = false

@description('Optional: Tags for resources')
param tags object = {}

@description('When true, disables public network access and deploys a private endpoint.')
param isPrivate bool = false

@description('Subnet resource id for the private endpoint (required when isPrivate=true)')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource id for Cosmos SQL API (required when isPrivate=true)')
param cosmosSqlPrivateDnsZoneId string = ''


// Use Azure Verified Module for Cosmos DB
module cosmosDb 'br:mcr.microsoft.com/bicep/avm/res/document-db/database-account:0.16.0' = {
  params: {
    name: cosmosAccountName
    location: location
    tags: tags
    capabilitiesToAdd: [
      'EnableServerless'
    ]
    databaseAccountOfferType: 'Standard'
    disableLocalAuthentication: true
    backupPolicyContinuousTier: 'Continuous7Days'
    networkRestrictions: {
      publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    }
    zoneRedundant: zoneRedundant
    sqlDatabases: [
      {
        name: cosmosDbName
        containers: [for container in cosmosDBContainerNames: {
            name: container.name
            paths: [container.partitionKey]
            kind: 'Hash'
          }
        ]
      }
    ]
    dataPlaneRoleDefinitions: [
      {
        // Cosmos DB Built-in Data Contributor: https://docs.azure.cn/en-us/cosmos-db/nosql/security/reference-data-plane-roles#cosmos-db-built-in-data-contributor
        roleName: 'Cosmos DB SQL Data Contributor'
        dataActions: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
        ]
        assignments: [
          for principalId in cosmosDBDataContributorPrincipalIds: {
            principalId: principalId
          }
        ]
      }
    ]
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
  dependsOn: [ cosmosDb ]
}

module pe 'private-endpoint.bicep' = if (isPrivate) {
  name: 'cosmos-pe-${uniqueString(cosmosAccountName)}'
  params: {
    name: '${cosmosAccountName}-pe'
    location: location
    subnetId: privateEndpointSubnetId
    targetResourceId: cosmosAccount.id
    groupIds: [ 'Sql' ]
    privateDnsZoneIds: empty(cosmosSqlPrivateDnsZoneId) ? [] : [ cosmosSqlPrivateDnsZoneId ]
    tags: tags
  }
}

output cosmosAccountName string = cosmosDb.outputs.name
output cosmosEndpoint string = cosmosDb.outputs.endpoint
output cosmosDBName string = cosmosDbName
