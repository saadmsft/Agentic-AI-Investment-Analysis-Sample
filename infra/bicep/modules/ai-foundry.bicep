@description('Optional: Location for all resources. Default is the resource group location')
param location string = resourceGroup().location

@description('Required: Base name used by the AI Foundry AVM pattern (max 12 chars)')
param aiFoundryBaseName string

@description('Managed Identity that will be given access to the AI Foundry Resource')
param roleAssignedManagedIdentityPrincipalIds string[]

@description('Tags for resources')
param tags object = {}

@description('When true, disables public network access and deploys the AI Foundry private endpoints via AVM.')
param isPrivate bool = false

@description('Agent service subnet id (optional; reserved for future Foundry agent runtime private networking)')
param agentServiceSubnetId string = ''

@description('Private DNS zone resource id for privatelink.openai.azure.com (required when isPrivate=true)')
param openAiPrivateDnsZoneId string = ''

@description('Private DNS zone resource id for privatelink.cognitiveservices.azure.com (required when isPrivate=true)')
param cognitiveServicesPrivateDnsZoneId string = ''

@description('Private DNS zone resource id for privatelink.services.ai.azure.com (required when isPrivate=true)')
param aiServicesPrivateDnsZoneId string = ''

// The AVM pattern creates the Cognitive Services account, the project, optional
// associated resources (Search/Cosmos/KV), and — when `networking` is supplied —
// the private endpoints + DNS zone groups. Passing the networking block also
// disables public network access on the underlying account.
var networkingConfig = isPrivate ? {
  agentServiceSubnetResourceId: agentServiceSubnetId
  aiServicesPrivateDnsZoneResourceId: aiServicesPrivateDnsZoneId
  cognitiveServicesPrivateDnsZoneResourceId: cognitiveServicesPrivateDnsZoneId
  openAiPrivateDnsZoneResourceId: openAiPrivateDnsZoneId
} : null

module aiFoundry 'br/public:avm/ptn/ai-ml/ai-foundry:0.5.0' = {
  params: {
    baseName: aiFoundryBaseName
    location: location
    tags: tags
    aiFoundryConfiguration: {
      allowProjectManagement: true
      createCapabilityHosts: false
      disableLocalAuth: true
      location: location
      networking: networkingConfig
      project: {
        desc: 'AI Foundry project for AI Investment Analysis Sample'
        displayName: 'AI-Invest'
        name: 'aiinvest-project'
      }
      roleAssignments: [
        for principalId in roleAssignedManagedIdentityPrincipalIds: {
          principalId: principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: '53ca6127-db72-4b80-b1b0-d745d6d5456d' // 'Azure AI User'
        }
      ]
      sku: 'S0'
    }
    aiModelDeployments: [
      {
        model: {
          format: 'OpenAI'
          name: 'gpt-4.1-mini'
          version: '2025-04-14'
        }
        name: 'gpt-4.1-mini'
        sku: {
          capacity: 100
          name: 'GlobalStandard'
        }
      }
    ]
    includeAssociatedResources: false
  }
}

output aiProjectName string = aiFoundry.outputs.aiProjectName
output aiServicesName string = aiFoundry.outputs.aiServicesName
