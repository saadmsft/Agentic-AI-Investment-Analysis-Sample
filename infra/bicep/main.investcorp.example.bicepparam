// Sample parameters file demonstrating InvestCorp custom naming convention.
// Replace the example names with whatever InvestCorp's standard prescribes
// (e.g. <org>-<workload>-<env>-<region>-<kind>-<seq>). Anything you leave
// empty falls back to the default `<namePrefix>-<kind>-<hash>` pattern.
//
// Usage:
//   az deployment group create -g <rg> \
//     --template-file infra/bicep/main.bicep \
//     --parameters infra/bicep/main.investcorp.example.bicepparam
//
// All names must satisfy Azure naming rules for the target resource type:
//   Storage account     3-24 lowercase alphanumerics
//   ACR                 5-50 alphanumerics
//   Cosmos DB account   3-44 lowercase alphanumerics + hyphens
//   Key Vault / web     3-24 alphanumerics + hyphens (not enforced here)
//   AI Foundry base     <= 12 lowercase alphanumerics (used as suffix base)

using './main.bicep'

// ---- Required core params ----
param isPrivate = true
param vnetAddressPrefix = '10.123.45.0/26'   // supplied by InvestCorp network team
param environment = 'prod'
param namePrefix = 'invscrp'                 // used only for any name you DON'T override

// ---- Optional explicit names (InvestCorp CAF) ----
// Pattern example: <org>-<workload>-<env>-<region>-<kind>-<seq>
param vnetNameOverride               = 'invs-aiinv-prod-bhc-vnet-001'
param userAssignedIdentityNameOverride = 'invs-aiinv-prod-bhc-uami-001'
param logAnalyticsWorkspaceNameOverride = 'invs-aiinv-prod-bhc-law-001'
param appInsightsNameOverride        = 'invs-aiinv-prod-bhc-appi-001'
param amplsNameOverride              = 'invs-aiinv-prod-bhc-ampls-001'
param storageAccountNameOverride     = 'invsaiinvprodbhcst001'           // 3-24 alphanumeric only
param cosmosAccountNameOverride      = 'invs-aiinv-prod-bhc-cosmos-001'
param containerRegistryNameOverride  = 'invsaiinvprodbhcacr001'          // alphanumeric only
param appServicePlanNameOverride     = 'invs-aiinv-prod-bhc-asp-001'
param aiFoundryBaseNameOverride      = 'invscaip01'                       // <= 12 lowercase chars
