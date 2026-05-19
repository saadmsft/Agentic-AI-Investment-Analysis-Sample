// Sample parameters file demonstrating the InvestCorp (IVC) naming convention
// for the "partnerfirms" workload. Anything you leave empty falls back to the
// default `<namePrefix>-<kind>-<hash>` pattern.
//
// Usage:
//   az deployment group create -g <rg> \
//     --template-file infra/bicep/main.bicep \
//     --parameters infra/bicep/main.investcorp.example.bicepparam
//
// Companion app deployments (api-app, web-app) — pass the App Service name
// overrides as env vars to infra/3-deploy-apps.sh, e.g.:
//   export API_APP_NAME_OVERRIDE=app-dev-ivc-aifoundry-partnerfirms-01
//   export WEB_APP_NAME_OVERRIDE=app-dev-ivc-aifoundry-partnerfirms-02
//
// All names must satisfy Azure naming rules for the target resource type:
//   Storage account     3-24 lowercase alphanumerics
//   ACR                 5-50 alphanumerics
//   Cosmos DB account   3-44 lowercase alphanumerics + hyphens
//   App Service         2-60 alphanumerics + hyphens (globally unique)
//   AI Foundry base     lowercase alphanumerics (drives Cognitive Services name)

using './main.bicep'

// ---- Required core params ----
param isPrivate = true
param investcorpEnv = true                   // IVC-managed network: skip NSGs, PEs, private DNS zones
param vnetAddressPrefix = '10.123.45.0/26' // supplied by InvestCorp network team
param environment = 'dev'
param namePrefix = 'invstdemo' // used only for any name you DON'T override

// ---- IVC naming convention (partnerfirms workload, eus2) ----
param vnetNameOverride = 'vnet-dev-aifoundry-eus2-01'
param userAssignedIdentityNameOverride = 'partnerfirms-dev-mngdid-01'
param logAnalyticsWorkspaceNameOverride = 'log-analytics-ws-dev-partnerfirms-eus2-01'
param appInsightsNameOverride = 'appinsights-app-dev-ivc-aifoundry-partnerfirms'
param amplsNameOverride = 'az-monitor-pls-partnerfirms-eus2-01'
// WARNING: IVC's requested storage name 'strgdevpartnerfirmseus201' is 25
// chars — Azure storage accounts are capped at 24. Trimmed to 24 chars below;
// confirm the final name with the IVC network/naming team before deploying.
param storageAccountNameOverride = 'strgdevpartnerfirmseus20' // 24 chars (was 25)
param cosmosAccountNameOverride = 'cosmosdb-dev-partnerfirms-ne-01'
param containerRegistryNameOverride = 'regpartnerfirmseus201' // alphanumeric only
param appServicePlanNameOverride = 'asp-app-dev-ivc-aifoundry-partnerfirms'
// NOTE: The AI Foundry AVM pattern enforces baseName maxLength=12 (lowercase
// alphanumeric). It is then concatenated with a 5-char unique suffix to form
// the actual Cognitive Services / Foundry account name. IVC's full preferred
// name "aifoundry-dev-partnerfirms-eus2-01" cannot be expressed directly; use
// a 12-char compliant base that still reads as IVC's workload.
param aiFoundryBaseNameOverride = 'aifoundrypf' // <= 12 lowercase alphanumeric chars
param aiFoundryProjectNameOverride = 'aiivcpartnerfirms-project'

// NOTE: Private endpoints, NICs, and private DNS zones are created manually
// by the InvestCorp network team — they are not managed by this template.
// The Foundry private endpoints (when isPrivate=true) require pre-existing
// private DNS zones; coordinate with the network team accordingly.
