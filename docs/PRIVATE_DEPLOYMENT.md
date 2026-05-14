# Private (Zero-Trust) Deployment Guide

This guide documents how to deploy, operate, and customize the Agentic AI Investment Analysis sample in its private / zero-trust topology (`isPrivate=true`). It is the companion to:

- [`_assets/ZERO_TRUST_ARCHITECTURE.md`](../_assets/ZERO_TRUST_ARCHITECTURE.md) — logical view of the topology
- [`infra/bicep/main.bicep`](../infra/bicep/main.bicep) — the Bicep template that provisions everything below
- [`infra/bicep/main.json`](../infra/bicep/main.json) — the compiled ARM template used by the **Deploy to Azure** button

> **TL;DR** — In private mode, every PaaS data plane is reached through a Private Endpoint inside a customer-owned VNet. **There is no public ingress on the workload — no Bastion and no jumpbox.** Operators are expected to deploy and reach the apps from the customer's own peered network (ExpressRoute, VPN, or hub VNet). No public DNS records exist for any workload.

---

## 1. Topology at a glance

<p align="center">
    <img src="../_assets/zero-trust-architecture.png" alt="Private Zero-Trust Architecture" style="max-width:800px;width:100%" />
</p>

| Plane         | Components                                                                                               | Public exposure                |
| ------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Operator      | Customer-managed peering (ExpressRoute / VPN / hub VNet) — no IP provisioned by this template            | None                           |
| Workload      | App Service Plan (Linux P0v3) hosting `api` + `web` Web Apps for Containers, ingress disabled publicly   | None                           |
| Data          | Cosmos DB (NoSQL), Storage Account (Blob), Azure AI Foundry / OpenAI, Azure Container Registry (Premium) | `publicNetworkAccess=Disabled` |
| Identity      | One User-Assigned Managed Identity (UAMI) federated to both apps                                         | n/a                            |
| Observability | Log Analytics + Application Insights joined to an Azure Monitor Private Link Scope (AMPLS)               | None                           |
| DNS           | Customer-owned Private DNS zones linked to the VNet                                                      | n/a                            |

---

## 2. Parameters reference

All parameters are defined in [`infra/bicep/main.bicep`](../infra/bicep/main.bicep).

### Naming & environment
| Parameter           | Default                 | Description                                                                                                         |
| ------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `namePrefix`        | `invstdemo`             | Lowercase prefix for every generated resource name. Keep ≤ 8 chars to stay within Storage / ACR limits.             |
| `environment`       | `dev`                   | Free-form environment tag (`dev` / `staging` / `prod`). `prod` enables Cosmos DB zone redundancy.                   |
| `location`          | resource group location | Region for VNet, App Service Plan, Cosmos, Storage, ACR, AMPLS.                                                     |
| `aiFoundryLocation` | resource group location | Region for Azure AI Foundry / model deployment. Use a region with model capacity (e.g. `swedencentral`, `eastus2`). |

### Networking & zero-trust
| Parameter           | Default      | Description                                                                                                                                                                                                                                            |
| ------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `isPrivate`         | `true`       | Master switch. `true` = full private deployment. `false` = legacy public demo, no VNet, no PEs.                                                                                                                                                        |
| `vnetAddressPrefix` | **required** | CIDR for the workload VNet. **Must be a `/26`** supplied by the customer (e.g. `10.123.45.0/26`). The template splits it into two equal `/27` subnets via `cidrSubnet()` — see §4. Required even when `isPrivate=false` (a placeholder is acceptable). |

### Application
| Parameter           | Default                         | Description                                                                             |
| ------------------- | ------------------------------- | --------------------------------------------------------------------------------------- |
| `cosmosDbName`      | `ai-investment-analysis-sample` | Logical Cosmos DB name. The template seeds the six containers used by the app (see §6). |
| `docsContainerName` | `opportunity-documents`         | Blob container used by document upload + processing services.                           |

---

## 3. What gets deployed

Each module in [`infra/bicep/modules/`](../infra/bicep/modules/) is conditional on `isPrivate` for its private-endpoint wiring. Modules with `*` are only deployed in private mode.

| Module                         | Resource                                                               | Public access                                                     | Auth model                                |
| ------------------------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------- |
| `network.bicep` *              | VNet (`/26`) + 2 subnets + NSGs                                        | n/a                                                               | n/a                                       |
| `private-dns.bicep` *          | 12 Private DNS zones, all VNet-linked                                  | n/a                                                               | n/a                                       |
| `user-assigned-identity.bicep` | One UAMI                                                               | n/a                                                               | Federated to both Web Apps                |
| `log-analytics-ws.bicep`       | Log Analytics workspace                                                | `disableLocalAuth=true`                                           | Entra ID + AMPLS                          |
| `app-insights.bicep`           | Application Insights (workspace-based)                                 | `disableLocalAuth=true`                                           | Entra ID + AMPLS                          |
| `ampls.bicep` *                | Azure Monitor Private Link Scope                                       | `PrivateOnly` ingestion + query                                   | n/a                                       |
| `storage.bicep`                | Storage account + blob container                                       | `allowSharedKeyAccess=false`, `publicNetworkAccess=Disabled`      | UAMI → Storage Blob Data Contributor      |
| `cosmos-db.bicep`              | Cosmos DB account, db, containers                                      | `disableLocalAuthentication=true`, `publicNetworkAccess=Disabled` | UAMI + deployer → Cosmos Data Contributor |
| `container-registry.bicep`     | ACR (Premium)                                                          | `adminUserEnabled=false`, `publicNetworkAccess=Disabled`          | UAMI → AcrPull / AcrPush / AcrDelete      |
| `app-service-plan.bicep`       | Linux App Service Plan (P0v3)                                          | n/a                                                               | n/a                                       |
| `web-app-container.bicep`      | (per app) Web App for Containers + VNet integration + private endpoint | Public ingress disabled                                           | UAMI                                      |
| `ai-foundry.bicep`             | Azure AI Services + Foundry project + model deployment                 | `publicNetworkAccess=Disabled`                                    | UAMI → Azure AI User                      |
| `private-endpoint.bicep` *     | Used by every PaaS module above                                        | n/a                                                               | n/a                                       |

> Operator access (Bastion + jumpbox) has been removed from this template. Operators must run scripts 2 + 3 from a workstation peered to the workload VNet.

---

## 4. Subnet layout

Defined in [`infra/bicep/modules/network.bicep`](../infra/bicep/modules/network.bicep). The customer supplies a single **/26** (64 IPs). The module splits it into two equal **/27** subnets using `cidrSubnet(vnetAddressPrefix, 27, n)`:

| Subnet          | Offset within /26 | CIDR example (`10.123.45.0/26`) | Purpose                                                                           | Delegation / Service endpoints                                                        |
| --------------- | ----------------- | ------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `snet-services` | 0 (first /27)     | `10.123.45.0/27`                | App Service VNet integration — all outbound calls from the API/Web apps           | Delegated `Microsoft.Web/serverFarms`, `Microsoft.CognitiveServices` service endpoint |
| `snet-pe`       | 32 (second /27)   | `10.123.45.32/27`               | All Private Endpoints (App Service inbound, ACR, Cosmos, Blob, AI Foundry, AMPLS) | None — `privateEndpointNetworkPolicies=Disabled`                                      |

**NSG posture:**
- `nsg-pe`: allow `VirtualNetwork → VirtualNetwork` TCP 443
- `nsg-services`: empty (permissive within VNet; App Service regional VNet integration manages its own outbound traffic)

**Sizing caveat.** /27 yields ~27 usable IPs per subnet. The App Service VNet integration subnet needs roughly 2× the worst-case instance count of the plan. If you expect autoscale beyond ~10 instances per plan, ask the customer for a larger CIDR (a `/25` would let you give each subnet a `/26`).

---

## 5. Private DNS zones

Defined in [`infra/bicep/modules/private-dns.bicep`](../infra/bicep/modules/private-dns.bicep). Every zone is linked to the workload VNet (`registrationEnabled=false`):

| Zone                                        | Used by                                               |
| ------------------------------------------- | ----------------------------------------------------- |
| `privatelink.documents.azure.com`           | Cosmos DB (SQL API)                                   |
| `privatelink.blob.${storageSuffix}`         | Storage account blob endpoint **and** AMPLS blob link |
| `privatelink.azurecr.io`                    | Azure Container Registry                              |
| `privatelink.openai.azure.com`              | Azure OpenAI deployment                               |
| `privatelink.cognitiveservices.azure.com`   | Cognitive Services account                            |
| `privatelink.services.ai.azure.com`         | AI Foundry project endpoint                           |
| `privatelink.azconfig.io`                   | App Configuration (optional)                          |
| `privatelink.monitor.azure.com`             | AMPLS                                                 |
| `privatelink.oms.opinsights.azure.com`      | Log Analytics ingestion                               |
| `privatelink.ods.opinsights.azure.com`      | Log Analytics agent data                              |
| `privatelink.agentsvc.azure-automation.net` | Monitor agents                                        |
| `privatelink.azurewebsites.net`             | App Service / Web App                                 |

> **Resolving private FQDNs from your peered network** — make sure the customer's on-prem DNS forwards `privatelink.*` zones to Azure DNS (`168.63.129.16`) over the peering, or replicate the zones in the customer's hub. Without this, your workstation will keep resolving public IPs and fail to reach the private endpoints.

---

## 6. Cosmos DB containers

Seeded by [`infra/bicep/modules/cosmos-db.bicep`](../infra/bicep/modules/cosmos-db.bicep) using the `cosmosDBContainerNames` array in `main.bicep`:

| Container               | Partition key     |
| ----------------------- | ----------------- |
| `opportunities`         | `/owner_id`       |
| `users`                 | `/email`          |
| `documents`             | `/opportunity_id` |
| `analysis`              | `/opportunity_id` |
| `workflow_events`       | `/analysis_id`    |
| `what_if_conversations` | `/analysis_id`    |

Local auth is disabled — the deployer principal **and** the workload UAMI are added as `Cosmos DB Built-in Data Contributor` so the FastAPI app authenticates via `DefaultAzureCredential`.

---

## 7. Identity & RBAC

A single User-Assigned Managed Identity is the workload identity for both Web Apps. Role assignments are issued by the individual modules:

| Scope                    | Role                                              | Why                               |
| ------------------------ | ------------------------------------------------- | --------------------------------- |
| ACR                      | `AcrPull`, `AcrPush`, `AcrDelete`                 | Image pull from App Service       |
| Storage account          | `Storage Blob Data Contributor`                   | Document upload / read by API app |
| Cosmos DB account        | `Cosmos DB Built-in Data Contributor`             | Plane-of-data CRUD without keys   |
| AI Foundry / AI Services | `Azure AI User`, `Cognitive Services OpenAI User` | Calling deployed model            |
| Log Analytics            | `Log Analytics Contributor`                       | Telemetry write                   |

The deployer (`deployer().objectId` in `main.bicep`) is also added as a Cosmos data contributor so you can run the FastAPI server from your workstation (over peering) against the deployed Cosmos.

---

## 8. App configuration in private mode

Application settings injected by [`infra/bicep/modules/web-app-container.bicep`](../infra/bicep/modules/web-app-container.bicep):

| App setting                                     | Source                                                                   |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| `AZURE_CLIENT_ID`                               | UAMI client ID — used by `DefaultAzureCredential`                        |
| `COSMOS_DB_ENDPOINT`                            | Cosmos account `documentEndpoint`                                        |
| `COSMOS_DB_DATABASE_NAME`                       | `cosmosDbName`                                                           |
| `AZURE_STORAGE_ACCOUNT_NAME`                    | Storage account name                                                     |
| `AZURE_STORAGE_CONTAINER_NAME`                  | `docsContainerName`                                                      |
| `AZURE_OPENAI_ENDPOINT`                         | Foundry project endpoint + model path + `api-version=2025-01-01-preview` |
| `AZURE_OPENAI_DEPLOYMENT_NAME`                  | Model deployment name                                                    |
| `APPLICATIONINSIGHTS_CONNECTION_STRING`         | App Insights (telemetry routed via AMPLS)                                |
| `ALLOW_ORIGINS`                                 | Internal Web App FQDN only — never `*`                                   |
| `WEBSITE_VNET_ROUTE_ALL` / `WEBSITE_DNS_SERVER` | Force all egress through VNet integration + private DNS                  |

Every setting is environment-driven; the same container image runs in either public or private mode without modification.

---

## 9. Deployment workflow

### Prerequisites

1. **A /26 CIDR** allocated by the customer's network team, not overlapping with any peered range.
2. **VNet peering already in place** (or planned to be set up before scripts 2 + 3 run) so that:
   - DNS for `privatelink.*` zones resolves to Azure DNS from your workstation.
   - TCP 443 reaches the workload's private endpoints (ACR, App Service).
3. Azure CLI ≥ 2.61, Docker (if using local builds), and the right Entra ID role assignments (`Contributor` + `User Access Administrator` on the target RG).

### Option A — Azure Portal one-click
Use the **Deploy to Azure** button in the [root README](../README.md#-one-click-azure-deployment). The portal wizard collects the parameters from §2 — including `vnetAddressPrefix` — and then provisions everything in §3. After it completes, jump to §10 to push images and roll out apps from your peered workstation.

### Option B — CLI

```bash
# 1. Provision infrastructure (VNet, PEs, AI Foundry, App Service Plan, …)
./infra/1-deploy-azure-infra.sh \
    -g <resource-group> \
    -l swedencentral \
    -p invstdemo \
    -e dev \
    --vnet-address-prefix 10.123.45.0/26

# 2. From a workstation peered to the workload VNet — build & push images
./infra/2-build-and-push-images.sh -r <acr>.azurecr.io

# 3. Roll out / update the api + web Web Apps
./infra/3-deploy-apps.sh -g <resource-group>
```

Flags accepted by `1-deploy-azure-infra.sh`:

| Flag                        | Description                                                             |
| --------------------------- | ----------------------------------------------------------------------- |
| `-g, --resource-group`      | **Required** target resource group                                      |
| `--vnet-address-prefix`     | **Required** — `/26` CIDR for the workload VNet (e.g. `10.123.45.0/26`) |
| `-l, --location`            | Region (default `westus2`)                                              |
| `-a, --ai-foundry-location` | AI Foundry region (default `swedencentral`)                             |
| `-p, --name-prefix`         | Resource name prefix (default `aiinvest`)                               |
| `-e, --environment`         | Environment tag                                                         |
| `--public`                  | Deploy the legacy public topology (`isPrivate=false`)                   |
| `-d, --debug`               | Enable Azure CLI debug logging                                          |

> **Why scripts 2 + 3 must run from a peered host:** ACR and App Service are `publicNetworkAccess=Disabled`, so `docker push` and the Web App rollout APIs are only reachable from inside the VNet.

---

## 10. Operating the deployment

### Connecting
There is no Bastion and no jumpbox. Reach the workload like any other private app:
- **Browse the Web app**: from a workstation on the peered network, navigate to `https://<webapp>.azurewebsites.net`. Private DNS forwarding must be in place (see §5).
- **Run admin commands**: `az` works directly against the resource group from anywhere; data-plane access (Cosmos, Storage, ACR `docker push`) requires the peering.

### Tearing down
```bash
az group delete -n <resource-group> --yes --no-wait
```
The Private DNS zones are inside the resource group, so a single group delete is sufficient.

---

## 11. Switching between public and private modes

The same template covers both modes through the `isPrivate` flag:

| Behavior                      | `isPrivate=true`        | `isPrivate=false`                   |
| ----------------------------- | ----------------------- | ----------------------------------- |
| VNet + subnets + NSGs         | ✅ created               | ❌ skipped                           |
| Private DNS zones             | ✅ 12 zones, VNet-linked | ❌ skipped                           |
| Private endpoints on PaaS     | ✅ on every data service | ❌ skipped                           |
| `publicNetworkAccess` on PaaS | `Disabled`              | `Enabled`                           |
| Web App ingress               | private endpoint only   | external                            |
| AMPLS                         | ✅                       | ❌ (telemetry over public ingestion) |

Use `--public` on `1-deploy-azure-infra.sh`, or pass `isPrivate=false` directly to the Bicep template, to switch. `vnetAddressPrefix` is still required at the parameter level — supply a placeholder such as `10.0.0.0/26` when running public.

---

## 12. Troubleshooting

| Symptom                                                                          | Likely cause                                                                 | Fix                                                                                                                                                                                     |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `403 PublicNetworkAccess is disabled` from your laptop                           | Trying to reach Cosmos / Storage / ACR from a non-peered network             | Run from a workstation peered to the workload VNet, or temporarily allow your IP via the resource's networking blade                                                                    |
| `docker push` fails with name-resolution error                                   | Private DNS zone for `privatelink.azurecr.io` not forwarded over the peering | Configure the customer's DNS to forward `privatelink.*` zones to Azure DNS (`168.63.129.16`), or replicate the zones in the customer's hub                                              |
| Web app cold-start fails to pull image                                           | UAMI missing `AcrPull` on ACR                                                | Re-run `1-deploy-azure-infra.sh` (idempotent) — module assigns the role                                                                                                                 |
| FastAPI returns `401` from Cosmos                                                | Deployer / UAMI not added as Cosmos Data Contributor                         | Verify with `az cosmosdb sql role assignment list -a <cosmos> -g <rg>`                                                                                                                  |
| `nslookup <appname>.azurewebsites.net` returns a public IP from your workstation | Web App private DNS zone not reachable from your network                     | See §5 — forward `privatelink.azurewebsites.net` to Azure DNS over the peering                                                                                                          |
| AI Foundry call fails with `OperationNotAllowed`                                 | Region mismatch — AI Services data plane not reachable via the configured PE | Set `aiFoundryLocation` to the same region as the rest of the deployment, or rely on the `Microsoft.CognitiveServices` service endpoint on `snet-services` (already enabled by default) |
| Bicep `cidrSubnet` error during deploy                                           | `vnetAddressPrefix` is not a `/26`                                           | Re-run with a `/26` CIDR (the script enforces this; the Bicep `cidrSubnet(..., 27, 1)` call assumes 64 addresses).                                                                      |

---

## 13. Related references

- [`_assets/ZERO_TRUST_ARCHITECTURE.md`](../_assets/ZERO_TRUST_ARCHITECTURE.md) — diagrams + zero-trust controls checklist
- [`infra/bicep/main.bicep`](../infra/bicep/main.bicep) — root template (resource-group scope)
- [`infra/bicep/modules/`](../infra/bicep/modules/) — per-resource modules
- [`infra/1-deploy-azure-infra.sh`](../infra/1-deploy-azure-infra.sh) — CLI deploy wrapper
- [`infra/2-build-and-push-images.sh`](../infra/2-build-and-push-images.sh) / [`3-deploy-apps.sh`](../infra/3-deploy-apps.sh) — image + app rollout (run from a peered host)
