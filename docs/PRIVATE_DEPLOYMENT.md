# Private (Zero-Trust) Deployment Guide

This guide documents **everything you need to deploy, operate, and customize the Agentic AI Investment Analysis sample in its private / zero-trust topology** (`isPrivate=true`). It is the companion to:

- [`_assets/ZERO_TRUST_ARCHITECTURE.md`](../_assets/ZERO_TRUST_ARCHITECTURE.md) — logical view of the topology
- [`infra/bicep/main.bicep`](../infra/bicep/main.bicep) — the Bicep template that provisions everything below
- [`infra/bicep/main.json`](../infra/bicep/main.json) — the compiled ARM template used by the **Deploy to Azure** button

> **TL;DR** — In private mode, every PaaS data plane is reached through a Private Endpoint inside a customer-owned VNet. The only public surface is the Azure Bastion control-plane TLS endpoint used by operators. No public DNS records exist for any workload.

---

## 1. Topology at a glance

<p align="center">
    <img src="../_assets/zero-trust-architecture.png" alt="Private Zero-Trust Architecture" style="max-width:800px;width:100%" />
</p>

| Plane | Components | Public exposure |
|---|---|---|
| Operator | Azure Bastion (Standard) → Linux jumpbox (no public IP) | Bastion TLS 443 only |
| Workload | App Service Plan (Linux P0v3) hosting `api` + `web` Web Apps for Containers, ingress disabled publicly | None |
| Data | Cosmos DB (NoSQL), Storage Account (Blob), Azure AI Foundry / OpenAI, Azure Container Registry (Premium) | `publicNetworkAccess=Disabled` |
| Identity | One User-Assigned Managed Identity (UAMI) federated to apps + jumpbox | n/a |
| Observability | Log Analytics + Application Insights joined to an Azure Monitor Private Link Scope (AMPLS) | None |
| DNS | Customer-owned Private DNS zones linked to the VNet | n/a |

---

## 2. Parameters reference

All parameters are defined in [`infra/bicep/main.bicep`](../infra/bicep/main.bicep).

### Naming & environment
| Parameter | Default | Description |
|---|---|---|
| `namePrefix` | `invstdemo` | Lowercase prefix for every generated resource name. Keep ≤ 8 chars to stay within Storage / ACR limits. |
| `environment` | `dev` | Free-form environment tag (`dev` / `staging` / `prod`). `prod` enables Cosmos DB zone redundancy. |
| `location` | resource group location | Region for VNet, ACA-replacement App Service Plan, Cosmos, Storage, ACR, Bastion, AMPLS. |
| `aiFoundryLocation` | resource group location | Region for Azure AI Foundry / model deployment. Use a region with model capacity (e.g. `swedencentral`, `eastus2`). |

### Networking & zero-trust
| Parameter | Default | Description |
|---|---|---|
| `isPrivate` | `true` | Master switch. `true` = full private deployment (everything in this doc). `false` = legacy public demo, no VNet, no PEs. |
| `vnetAddressPrefix` | `10.50.0.0/16` | CIDR for the VNet. Must accommodate every subnet listed in §4. |
| `deployJumpbox` | `true` | When `true` (and `isPrivate=true`), provisions the Linux jumpbox + Bastion. |
| `jumpboxAdminUsername` | `azureuser` | Local admin user on the jumpbox. |
| `jumpboxAdminPublicKey` | _(empty, secure)_ | **Required when `deployJumpbox=true`**. Paste the contents of an OpenSSH public key (e.g. `~/.ssh/id_rsa.pub`). |
| `bastionSku` | `Standard` | `Standard` is required for native-client SSH tunneling used by [`infra/0-connect-jumpbox.sh`](../infra/0-connect-jumpbox.sh). |

### Application
| Parameter | Default | Description |
|---|---|---|
| `cosmosDbName` | `ai-investment-analysis-sample` | Logical Cosmos DB name. The template seeds the six containers used by the app (see §6). |
| `docsContainerName` | `opportunity-documents` | Blob container used by document upload + processing services. |

---

## 3. What gets deployed

Each module in [`infra/bicep/modules/`](../infra/bicep/modules/) is conditional on `isPrivate` for its private-endpoint wiring. Modules with `*` are only deployed in private mode.

| Module | Resource | Public access | Auth model |
|---|---|---|---|
| `network.bicep` * | VNet + 6 subnets + NSGs | n/a | n/a |
| `private-dns.bicep` * | 12 Private DNS zones, all VNet-linked | n/a | n/a |
| `user-assigned-identity.bicep` | One UAMI | n/a | Federated to apps + jumpbox |
| `log-analytics-ws.bicep` | Log Analytics workspace | `disableLocalAuth=true` | Entra ID + AMPLS |
| `app-insights.bicep` | Application Insights (workspace-based) | `disableLocalAuth=true` | Entra ID + AMPLS |
| `ampls.bicep` * | Azure Monitor Private Link Scope | `PrivateOnly` ingestion + query | n/a |
| `storage.bicep` | Storage account + blob container | `allowSharedKeyAccess=false`, `publicNetworkAccess=Disabled` | UAMI → Storage Blob Data Contributor |
| `cosmos-db.bicep` | Cosmos DB account, db, containers | `disableLocalAuthentication=true`, `publicNetworkAccess=Disabled` | UAMI + deployer → Cosmos Data Contributor |
| `container-registry.bicep` | ACR (Premium) | `adminUserEnabled=false`, `publicNetworkAccess=Disabled` | UAMI → AcrPull / AcrPush / AcrDelete |
| `app-service-plan.bicep` | Linux App Service Plan (P0v3) | n/a | n/a |
| `web-app-container.bicep` | (per app) Web App for Containers + VNet integration + private endpoint | Public ingress disabled | UAMI |
| `ai-foundry.bicep` | Azure AI Services + Foundry project + model deployment | `publicNetworkAccess=Disabled` | UAMI → Azure AI User |
| `bastion.bicep` * | Azure Bastion (`Standard`) | TLS 443 only | Operator Entra ID |
| `jumpbox.bicep` * | Linux VM, no public IP, UAMI attached | n/a | SSH key (Bastion-tunneled) |
| `private-endpoint.bicep` * | Used by every PaaS module above | n/a | n/a |

> The legacy `container-apps-environment.bicep` is retained on disk for reference but is no longer instantiated — the workload now runs on App Service.

---

## 4. Subnet layout

Defined in [`infra/bicep/modules/network.bicep`](../infra/bicep/modules/network.bicep). Default sizes given for `vnetAddressPrefix=10.50.0.0/16`:

| Subnet | CIDR | Purpose | Delegation / Service endpoints |
|---|---|---|---|
| `snet-appsvc` | /23 | App Service VNet integration | Delegated `Microsoft.Web/serverFarms`, `Microsoft.CognitiveServices` service endpoint |
| `snet-pe` | /26 | All Private Endpoints (ACR, Cosmos, Blob, AI Foundry, AMPLS, App Service) | None |
| `snet-jumpbox` | /27 | Jumpbox NIC (no public IP) | None |
| `AzureBastionSubnet` | /26 | Required name for Azure Bastion | None |
| `snet-build` | /27 | Reserved — ACR Tasks / private build agents | None |
| `snet-mgmt` | /27 | Reserved — self-hosted CI/CD runners | None |

**NSG posture (deny-by-default with explicit allows):**
- `nsg-pe`: allow VNet→VNet TCP 443
- `nsg-jumpbox`: allow VNet TCP 22/3389 (Bastion only)
- `nsg-bastion`: full Bastion ruleset per Microsoft docs (HTTPS in, GatewayManager, Load Balancer, SSH/RDP out, AzureCloud:443 out)
- `nsg-aca` (legacy, kept empty): platform-managed when ACA was used

---

## 5. Private DNS zones

Defined in [`infra/bicep/modules/private-dns.bicep`](../infra/bicep/modules/private-dns.bicep). Every zone is linked to the workload VNet (`registrationEnabled=false`):

| Zone | Used by |
|---|---|
| `privatelink.documents.azure.com` | Cosmos DB (SQL API) |
| `privatelink.blob.${storageSuffix}` | Storage account blob endpoint **and** AMPLS blob link |
| `privatelink.azurecr.io` | Azure Container Registry |
| `privatelink.openai.azure.com` | Azure OpenAI deployment |
| `privatelink.cognitiveservices.azure.com` | Cognitive Services account |
| `privatelink.services.ai.azure.com` | AI Foundry project endpoint |
| `privatelink.azconfig.io` | App Configuration (optional) |
| `privatelink.monitor.azure.com` | AMPLS |
| `privatelink.oms.opinsights.azure.com` | Log Analytics ingestion |
| `privatelink.ods.opinsights.azure.com` | Log Analytics agent data |
| `privatelink.agentsvc.azure-automation.net` | Monitor agents |
| `privatelink.azurewebsites.net` | App Service / Web App |

---

## 6. Cosmos DB containers

Seeded by [`infra/bicep/modules/cosmos-db.bicep`](../infra/bicep/modules/cosmos-db.bicep) using the `cosmosDBContainerNames` array in `main.bicep`:

| Container | Partition key |
|---|---|
| `opportunities` | `/owner_id` |
| `users` | `/email` |
| `documents` | `/opportunity_id` |
| `analysis` | `/opportunity_id` |
| `workflow_events` | `/analysis_id` |
| `what_if_conversations` | `/analysis_id` |

Local auth is disabled — the deployer principal **and** the workload UAMI are added as `Cosmos DB Built-in Data Contributor` so the FastAPI app authenticates via `DefaultAzureCredential`.

---

## 7. Identity & RBAC

A single User-Assigned Managed Identity is the workload identity for both Web Apps and the jumpbox. Role assignments are issued by the individual modules:

| Scope | Role | Why |
|---|---|---|
| ACR | `AcrPull`, `AcrPush`, `AcrDelete` | Image pull from App Service + push from jumpbox |
| Storage account | `Storage Blob Data Contributor` | Document upload / read by API app |
| Cosmos DB account | `Cosmos DB Built-in Data Contributor` | Plane-of-data CRUD without keys |
| AI Foundry / AI Services | `Azure AI User`, `Cognitive Services OpenAI User` | Calling deployed model |
| Resource group | `Contributor` (jumpbox only, when `deployJumpbox=true`) | Lets `2-build-and-push-images.sh` and `3-deploy-apps.sh` run from the jumpbox |
| Log Analytics | `Log Analytics Contributor` | Telemetry write |

The deployer (`deployer().objectId` in `main.bicep`) is added as a Cosmos data contributor as well, so you can run the FastAPI server from your laptop against the deployed Cosmos when you punch a temporary firewall hole or run from the jumpbox.

---

## 8. App configuration in private mode

Application settings injected by [`infra/bicep/modules/web-app-container.bicep`](../infra/bicep/modules/web-app-container.bicep):

| App setting | Source |
|---|---|
| `AZURE_CLIENT_ID` | UAMI client ID — used by `DefaultAzureCredential` |
| `COSMOS_DB_ENDPOINT` | Cosmos account `documentEndpoint` |
| `COSMOS_DB_DATABASE_NAME` | `cosmosDbName` |
| `AZURE_STORAGE_ACCOUNT_NAME` | Storage account name |
| `AZURE_STORAGE_CONTAINER_NAME` | `docsContainerName` |
| `AZURE_OPENAI_ENDPOINT` | Foundry project endpoint + model path + `api-version=2025-01-01-preview` |
| `AZURE_OPENAI_DEPLOYMENT_NAME` | Model deployment name |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights (telemetry routed via AMPLS) |
| `ALLOW_ORIGINS` | Internal Web App FQDN only — never `*` |
| `WEBSITE_VNET_ROUTE_ALL` / `WEBSITE_DNS_SERVER` | Force all egress through VNet integration + private DNS |

Every setting is environment-driven; the same container image runs in either public or private mode without modification.

---

## 9. Deployment workflow

### Option A — Azure Portal one-click
Use the **Deploy to Azure** button in the [root README](../README.md#-one-click-azure-deployment). The portal wizard collects the parameters from §2 and then provisions everything in §3. After it completes, jump to §10 to push images and roll out apps.

### Option B — CLI (recommended for end-to-end automation)

```bash
# 1. Provision infrastructure (VNet, PEs, AI Foundry, jumpbox, …)
./infra/1-deploy-azure-infra.sh \
    -g <resource-group> \
    -l swedencentral \
    -p invstdemo \
    -e dev \
    --ssh-key-file ~/.ssh/id_rsa.pub

# 2. Open an SSH tunnel into the jumpbox via Bastion
./infra/0-connect-jumpbox.sh -g <resource-group>

# On the jumpbox:
git clone https://github.com/Azure-Samples/Agentic-AI-Investment-Analysis-Sample.git
cd Agentic-AI-Investment-Analysis-Sample

# 3. Build & push container images to the private ACR (uses UAMI on the jumpbox)
./infra/2-build-and-push-images.sh -g <resource-group>

# 4. Roll out / update the api + web Web Apps
./infra/3-deploy-apps.sh -g <resource-group>
```

Flags accepted by `1-deploy-azure-infra.sh`:

| Flag | Description |
|---|---|
| `-g, --resource-group` | **Required** target resource group |
| `-l, --location` | Region (default `westus2`) |
| `-a, --ai-foundry-location` | AI Foundry region (default `swedencentral`) |
| `-p, --name-prefix` | Resource name prefix (default `aiinvest`) |
| `-e, --environment` | Environment tag |
| `--public` | Deploy the legacy public topology (`isPrivate=false`) |
| `--no-jumpbox` | Skip jumpbox + Bastion |
| `--ssh-key-file <path>` | Public key for the jumpbox (default `~/.ssh/id_rsa.pub`) |
| `--bastion-sku <Basic\|Standard>` | Default `Standard` |
| `-d, --debug` | Enable Azure CLI debug logging |

> **Why scripts 2 + 3 must run from the jumpbox in private mode:** ACR is `publicNetworkAccess=Disabled`, so `docker push` and the Web App rollout APIs are only reachable from inside the VNet.

---

## 10. Operating the deployment

### Connecting
```bash
./infra/0-connect-jumpbox.sh -g <resource-group>
```
Internally this runs `az network bastion ssh --auth-type ssh-key`, which requires Bastion **Standard** SKU.

### Reaching the Web app from your laptop
The Web app has internal-only ingress. To browse it during development, open an additional Bastion tunnel from the jumpbox to the Web app FQDN, or deploy a self-service VPN gateway / Azure Front Door Premium with Private Link in front of it. The sample does **not** ship a VPN gateway — Bastion + jumpbox is the documented path.

### Rotating the jumpbox key
Re-run `1-deploy-azure-infra.sh --ssh-key-file <new.pub>` against the same resource group; the VM extension rewrites `authorized_keys`.

### Tearing down
```bash
az group delete -n <resource-group> --yes --no-wait
```
The Private DNS zones are inside the resource group, so a single group delete is sufficient.

---

## 11. Switching between public and private modes

The same template covers both modes through the `isPrivate` flag:

| Behavior | `isPrivate=true` | `isPrivate=false` |
|---|---|---|
| VNet + subnets + NSGs | ✅ created | ❌ skipped |
| Private DNS zones | ✅ 12 zones, VNet-linked | ❌ skipped |
| Private endpoints on PaaS | ✅ on every data service | ❌ skipped |
| `publicNetworkAccess` on PaaS | `Disabled` | `Enabled` |
| Web App ingress | internal only | external |
| Jumpbox + Bastion | optional via `deployJumpbox` | always skipped |
| AMPLS | ✅ | ❌ (telemetry over public ingestion) |

Use `--public` on `1-deploy-azure-infra.sh`, or pass `isPrivate=false` directly to the bicep template, to switch.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `403 PublicNetworkAccess is disabled` from your laptop | Trying to reach Cosmos / Storage / ACR from the public internet | Use the jumpbox or temporarily allow your IP via the resource's networking blade |
| `Bastion: target resource id not found` | Bastion SKU is `Basic` | Redeploy with `--bastion-sku Standard` |
| `docker push` fails on the jumpbox with name-resolution error | Private DNS zone link not yet propagated | Wait 1–2 minutes after `1-deploy-azure-infra.sh` finishes; re-run `nslookup <acr>.azurecr.io` |
| Web app cold-start fails to pull image | UAMI missing `AcrPull` on ACR | Re-run `1-deploy-azure-infra.sh` (idempotent) — module assigns the role |
| FastAPI returns `401` from Cosmos | Deployer / UAMI not added as Cosmos Data Contributor | Verify with `az cosmosdb sql role assignment list -a <cosmos> -g <rg>` |
| `nslookup <appname>.azurewebsites.net` returns a public IP from the jumpbox | Web App private endpoint not yet linked to `privatelink.azurewebsites.net` | Confirm the zone exists and is VNet-linked; re-run rollout |
| AI Foundry call fails with `OperationNotAllowed` | Region mismatch — AI Services data plane not reachable via the configured PE | Set `aiFoundryLocation` to the same region as the rest of the deployment, or open an outbound `Microsoft.CognitiveServices` service endpoint on `snet-appsvc` (already enabled by default) |

---

## 13. Related references

- [`_assets/ZERO_TRUST_ARCHITECTURE.md`](../_assets/ZERO_TRUST_ARCHITECTURE.md) — diagrams + zero-trust controls checklist
- [`infra/bicep/main.bicep`](../infra/bicep/main.bicep) — root template (resource-group scope)
- [`infra/bicep/modules/`](../infra/bicep/modules/) — per-resource modules
- [`infra/1-deploy-azure-infra.sh`](../infra/1-deploy-azure-infra.sh) — CLI deploy wrapper
- [`infra/0-connect-jumpbox.sh`](../infra/0-connect-jumpbox.sh) — Bastion SSH tunnel
- [`infra/2-build-and-push-images.sh`](../infra/2-build-and-push-images.sh) / [`3-deploy-apps.sh`](../infra/3-deploy-apps.sh) — image + app rollout (run on the jumpbox in private mode)
