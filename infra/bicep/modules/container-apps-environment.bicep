@description('Name of the Container Apps Environment')
param containerAppsEnvironmentName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Log Analytics workspace id output from log-analytics-ws.bicep module')
param logAnalyticsWorkspaceId string

@description('Log Analytics workspace primary shared key output from log-analytics-ws.bicep module')
@secure()
param logAnalyticsPrimarySharedKey string 

@description('User Assigned Identity resource IDs that will be assigned to the Container Apps Environment')
param userAssignedResourceIds string[]

@description('Tags for resources')
param tags object = {}

@description('When true, makes the ACA environment internal (VNet-integrated, no public ingress).')
param isPrivate bool = false

@description('ACA infrastructure subnet id (required when isPrivate=true). Must be /23 or larger, delegated to Microsoft.App/environments.')
param infrastructureSubnetId string = ''


// Use Azure Verified Module for Container Apps Environment
module containerAppsEnvironment 'br:mcr.microsoft.com/bicep/avm/res/app/managed-environment:0.11.3' = {
  name: 'containerAppsEnvironmentDeployment'
  params: {
    name: containerAppsEnvironmentName
    location: location
    tags: tags
    zoneRedundant: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspaceId
        sharedKey: logAnalyticsPrimarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    infrastructureSubnetResourceId: isPrivate ? infrastructureSubnetId : ''
    internal: isPrivate
    platformReservedCidr: isPrivate ? '' : '172.17.17.0/24'
    platformReservedDnsIP: isPrivate ? '' : '172.17.17.17'
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: userAssignedResourceIds
    }
  }
}


output name string = containerAppsEnvironment.outputs.name
output resourceId string = containerAppsEnvironment.outputs.resourceId
output systemAssignedMIPrincipalId string? = containerAppsEnvironment.outputs.?systemAssignedMIPrincipalId
output defaultDomain string = containerAppsEnvironment.outputs.defaultDomain
output staticIp string = containerAppsEnvironment.outputs.staticIp
output domainVerificationId string = containerAppsEnvironment.outputs.domainVerificationId
