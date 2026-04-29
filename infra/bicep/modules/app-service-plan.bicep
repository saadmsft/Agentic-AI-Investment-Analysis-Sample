// Linux App Service Plan used to host both the API and Web container apps.
// Uses Premium v3 SKU because private endpoints + VNet integration are
// supported on PremiumV2/V3 and Standard (S1+). For demos, B-series tiers
// also support PE/VNet on Linux.

@description('Name of the App Service Plan')
param name string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Tags applied to the plan')
param tags object = {}

@description('SKU name for the App Service Plan. P0v3 is the cheapest V3 SKU available in Sweden Central.')
param skuName string = 'P0v3'

@description('SKU tier (must match skuName family).')
param skuTier string = 'PremiumV3'

@description('Number of instances')
param skuCapacity int = 1

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: skuName
    tier: skuTier
    capacity: skuCapacity
  }
  properties: {
    reserved: true // Linux
    zoneRedundant: false
  }
}

output id string = plan.id
output name string = plan.name
