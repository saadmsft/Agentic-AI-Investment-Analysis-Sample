# InvestCorp – Zero-Trust Deployment Package

> **Solution**: Agentic AI Investment Analysis Sample (private / zero-trust topology)
> **Target**: InvestCorp, Bahrain
> **Validated**: 14 May 2026 in `MCAPS-Hybrid-AI&HPC-Saad` / `swedencentral`
> **Author**: Cloud Accelerate Factory

This document is the single source of truth for deploying the solution into an InvestCorp Azure subscription. It records **what is provisioned**, **what network controls are needed**, **what the operator workstation must be able to reach during bootstrap**, and **what temporary exceptions the operator must request from the InvestCorp network / security team**.

It is the companion to:
- [PRIVATE_DEPLOYMENT.md](./PRIVATE_DEPLOYMENT.md) — engineering-grade reference
- [`infra/bicep/main.bicep`](../infra/bicep/main.bicep) — the template that does the work
- [`_assets/zero-trust-architecture.png`](../_assets/zero-trust-architecture.png) — logical view

---

## 1. Executive summary

| Item                       | Value                                                                                                                                                    |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deployment model           | Single Azure resource group, single VNet (customer-supplied `/26`), zero public ingress on the workload                                                  |
| Region (recommended)       | `uaenorth` or `qatarcentral` for data residency, **or** `swedencentral` if model capacity in MENA is constrained (Foundry gpt-4.1-mini is available)     |
| Topology                   | App Service Plan (Linux) hosting two containerised Web Apps + private PaaS dependencies, all reachable only through Private Endpoints                    |
| Operator access            | **No Bastion, no jumpbox is provisioned by the template**. Operators run scripts 2 & 3 from a workstation reachable via ExpressRoute / VPN / hub peering |
| Egress from apps           | Routed through the VNet (`WEBSITE_VNET_ROUTE_ALL=1`) to Private Endpoints + service endpoint for AI Foundry                                              |
| Identity                   | One User-Assigned Managed Identity (UAMI) federated to both apps. No keys, no shared secrets                                                             |
| Validated end-to-end       | Yes — IVC mode (`investcorpEnv=true`) deployed in `swedencentral`, both apps return `HTTP 200` after the documented temp public-access exceptions; see Appendix D for the full playbook                |
| Estimated monthly Azure $$ | ≈ **US $620 – 780 / month** at idle in Sweden Central (see §3.3). Excludes Foundry token consumption.                                                    |

---

## 2. Logical architecture

![Zero-trust architecture](../_assets/zero-trust-architecture.png)

Diagram source: [`_assets/zero-trust-architecture.mmd`](../_assets/zero-trust-architecture.mmd) (Mermaid) and [`docs/diagrams/private_architecture.py`](./diagrams/private_architecture.py) (mingrammer/diagrams Python).

---

## 3. What gets deployed

### 3.1 Resource inventory (production-grade)

This is the exact set of resources observed in the validation deployment (`rg-aiinvest-test` / `swedencentral`). Every public data-plane is disabled unless flagged otherwise.

| #   | Azure resource type                                  | SKU / tier                           | Count | Public network             | Purpose                                     |
| --- | ---------------------------------------------------- | ------------------------------------ | ----- | -------------------------- | ------------------------------------------- |
| 1   | `Microsoft.Network/virtualNetworks`                  | n/a                                  | 1     | n/a                        | Workload VNet `/26`                         |
| 2   | `Microsoft.Network/networkSecurityGroups`            | n/a                                  | 2     | n/a                        | NSGs for `snet-services` + `snet-pe`        |
| 3   | `Microsoft.Network/privateDnsZones`                  | n/a                                  | 12    | n/a                        | privatelink zones (see §3.2)                |
| 4   | `Microsoft.Network/privateEndpoints`                 | n/a                                  | 6     | n/a                        | api / web / ACR / Cosmos / Blob / AMPLS     |
| 5   | `Microsoft.Web/serverfarms`                          | **`P0v3`** (Linux)                   | 1     | n/a                        | App Service Plan                            |
| 6   | `Microsoft.Web/sites` (`app,linux,container`)        | shares ASP                           | 2     | **Disabled**               | `*-api-dev` + `*-web-dev` containers        |
| 7   | `Microsoft.ContainerRegistry/registries`             | **`Premium`**                        | 1     | **Disabled**               | Required for PE on ACR                      |
| 8   | `Microsoft.DocumentDB/databaseAccounts`              | NoSQL, `Continuous7Days` backup      | 1     | **Disabled**               | Cosmos DB, `disableLocalAuth=true`          |
| 9   | `Microsoft.Storage/storageAccounts`                  | **`Standard_LRS` / `StorageV2`**     | 1     | **Disabled**               | Blob, `allowSharedKeyAccess=false`          |
| 10  | `Microsoft.CognitiveServices/accounts`               | **`S0` / `AIServices`**              | 1     | **Enabled** + networkAcls¹ | Azure AI Foundry account                    |
| 11  | `Microsoft.CognitiveServices/accounts/projects`      | inherits S0                          | 1     | n/a                        | Foundry project `aiinvest-project`          |
| 12  | Model deployment (gpt-4.1-mini)                      | **`GlobalStandard` capacity `100`**  | 1     | n/a                        | LLM used by the agent                       |
| 13  | `Microsoft.ManagedIdentity/userAssignedIdentities`   | n/a                                  | 1     | n/a                        | UAMI federated to both apps                 |
| 14  | `Microsoft.OperationalInsights/workspaces`           | PerGB                                | 1     | Disabled¹                  | Log Analytics, `disableLocalAuth=true`      |
| 15  | `Microsoft.Insights/components` (App Insights)       | workspace-based                      | 1     | Disabled¹                  | App telemetry, `disableLocalAuth=true`      |
| 16  | `microsoft.insights/privateLinkScopes`               | n/a                                  | 1     | n/a                        | AMPLS joining LAW + AppInsights             |

¹ AI Foundry: `publicNetworkAccess=Enabled` at the account level but `networkAcls.defaultAction=Deny`, with a VNet rule for `snet-services`. Plus a Private Endpoint on `services.ai.azure.com` (recommended hardening: also set `publicNetworkAccess=Disabled` after bootstrap — see §6.3).
¹ AMPLS Log Analytics: ingestion & query are forced through the Private Link Scope (`PrivateOnly`).

### 3.2 Private DNS zones provisioned (12)

All linked to the workload VNet. **Customer must also link these to whichever VNet operators are calling from** (or forward `privatelink.*` to Azure DNS over peering).

| Zone                                       | Used by                                          |
| ------------------------------------------ | ------------------------------------------------ |
| `privatelink.azurewebsites.net`            | API + Web App Service                            |
| `privatelink.azurecr.io`                   | Azure Container Registry                         |
| `privatelink.documents.azure.com`          | Cosmos DB (SQL API)                              |
| `privatelink.blob.core.windows.net`        | Storage (blob)                                   |
| `privatelink.cognitiveservices.azure.com`  | AI Foundry / Cognitive Services data plane       |
| `privatelink.openai.azure.com`             | OpenAI inference endpoints                       |
| `privatelink.services.ai.azure.com`        | Foundry project endpoints                        |
| `privatelink.monitor.azure.com`            | AMPLS                                            |
| `privatelink.oms.opinsights.azure.com`     | AMPLS / agent                                    |
| `privatelink.ods.opinsights.azure.com`     | AMPLS / ingest                                   |
| `privatelink.agentsvc.azure-automation.net`| AMPLS (Monitor agent)                            |
| `privatelink.azconfig.io`                  | Reserved (App Configuration; not currently used) |

### 3.3 Cost estimate (idle, US $, May 2026 list prices)

Use [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) for an InvestCorp-specific quote. Indicative monthly cost in Sweden Central at idle:

| Item                                       | Approx US $/month |
| ------------------------------------------ | ----------------- |
| App Service Plan `P0v3` Linux              | ~ 88              |
| Azure Container Registry **Premium**       | ~ 167             |
| Cosmos DB NoSQL (1000 RU/s, 7-day PITR)    | ~ 80              |
| Storage account (LRS, low traffic)         | ~ 5               |
| AI Foundry / OpenAI (gpt-4.1-mini, idle)   | ~ 0 (pay per use) |
| Log Analytics + App Insights (PerGB)       | ~ 30 (small)      |
| 6 × Private Endpoints                      | ~ 50              |
| Private DNS zones                          | < 5               |
| **Optional**: Bastion Basic + Public IP    | ~ 138             |
| **Subtotal idle (no Bastion)**             | **≈ 425**         |
| **Subtotal idle (with Bastion)**           | **≈ 563**         |

Add LLM token cost on top: `gpt-4.1-mini` GlobalStandard is currently $0.40 / 1M input tokens and $1.60 / 1M output tokens.

---

## 4. Network requirements (ask the InvestCorp network team)

### 4.1 Workload VNet

| Need                                 | Detail                                                                                                                                                |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CIDR**                             | **One `/26` block** (64 IPs) that does **not overlap** any peered hub / on-prem range. The template splits it into `snet-services` and `snet-pe` /27s |
| Peering                              | Bidirectional peering between this VNet and the InvestCorp hub (or ExpressRoute / VPN gateway VNet). `allow-forwarded-traffic=true` recommended       |
| DNS                                  | The hub DNS server must forward all `privatelink.*` zones to Azure DNS `168.63.129.16`, **or** the 12 zones must be linked to the hub VNet as well    |
| Outbound from apps                   | App Service VNet integration routes all egress to the VNet; firewall the VNet egress like any other workload subnet                                   |
| Operator workstation reachability    | The workstation that runs scripts 2 & 3 must be able to resolve and reach `*.azurecr.io`, `*.azurewebsites.net`, `*.documents.azure.com`, `*.blob.core.windows.net` **on their private IPs** via peering |

### 4.2 NSG rules added by the template (informational)

| NSG                                 | Inbound default          | Outbound default                       |
| ----------------------------------- | ------------------------ | -------------------------------------- |
| `*-nsg-services`                    | Deny all from internet   | Allow VNet → Azure services (TCP 443)  |
| `*-nsg-pe`                          | Deny all from internet   | Default                                |

No internet inbound is ever permitted on the workload subnets.

---

## 5. Operator workstation prerequisites & outbound URL whitelist

The "operator workstation" is whatever box runs `infra/1-deploy-azure-infra.sh`, `infra/2-build-and-push-images.sh`, `infra/3-deploy-apps.sh`. It can be a laptop on InvestCorp corporate network, an Azure Cloud Shell that has been joined to a peered VNet, a Windows Server / Linux VM in the InvestCorp hub, or a self-hosted Azure DevOps agent.

### 5.1 Required tooling

| Tool                | Min version | Used by             | Install reference                                                                                  |
| ------------------- | ----------- | ------------------- | -------------------------------------------------------------------------------------------------- |
| Azure CLI (`az`)    | 2.65+       | All 3 scripts       | `brew install azure-cli` / [docs.microsoft.com/cli/azure](https://learn.microsoft.com/cli/azure)   |
| Bicep CLI           | 0.32+       | Script 1            | `az bicep install`                                                                                 |
| Docker Engine       | 24+         | Script 2 (`--docker`) | Docker Desktop / `apt install docker.io`                                                          |
| Node.js + npm       | 18 LTS+     | Script 2 (web build)| [nodejs.org](https://nodejs.org/en/download)                                                       |
| Python 3            | 3.10+       | Script 1 helpers    | Usually pre-installed; otherwise [python.org](https://www.python.org/downloads/)                   |
| `jq`                | 1.6+        | Script 3 outputs    | `brew install jq` / `apt install jq`                                                               |
| `bash`              | 4+          | Script 1/2/3        | macOS / Linux / WSL2                                                                               |
| `git`               | any         | Cloning the repo    | `apt install git`                                                                                  |

### 5.2 Outbound URLs the workstation must reach during bootstrap

These are **only required while the operator runs scripts 1 → 3**. They can be revoked after deployment completes. Group by purpose:

#### A. Microsoft control plane & Entra ID (always needed for `az`)

| Destination                            | Port | Reason                                            |
| -------------------------------------- | ---- | ------------------------------------------------- |
| `login.microsoftonline.com`            | 443  | Entra ID login for `az login`                     |
| `login.microsoft.com`                  | 443  | Token issuance                                    |
| `graph.microsoft.com`                  | 443  | RBAC lookups (`az ad signed-in-user`)             |
| `management.azure.com`                 | 443  | ARM control plane (all `az` resource commands)    |
| `management.core.windows.net`          | 443  | Legacy ARM                                        |
| `*.cognitiveservices.azure.com` (mgmt) | 443  | Cognitive Services control plane                  |
| `aka.ms`                               | 443  | `az` CLI redirects + Bicep release downloads      |
| `mcr.microsoft.com`                    | 443  | Pull `azure-cli` / Bicep / Foundry containers     |

#### B. Azure data plane (for image push + final smoke test)

These must be reachable on **public IPs only during bootstrap** if the operator is NOT yet peered. If the operator workstation is already peered, they should resolve to private IPs and **public access is not needed**.

| Destination                                              | Port | Purpose                                       |
| -------------------------------------------------------- | ---- | --------------------------------------------- |
| `<acr>.azurecr.io`                                       | 443  | `docker push` or `az acr build` for images    |
| `<acr>.privatelink.azurecr.io`                           | 443  | Private FQDN (only via peering)               |
| `*.blob.core.windows.net` (region-specific)              | 443  | Storage data plane                            |
| `*.documents.azure.com` (region-specific)                | 443  | Cosmos data plane                             |
| `*.azurewebsites.net`                                    | 443  | App Service ingress (only via peering)        |

#### C. Bootstrap supply chain (script 2 build step pulls these)

| Destination                       | Port | Purpose                                                                                                                          |
| --------------------------------- | ---- | -------------------------------------------------------------------------------------------------------------------------------- |
| `registry.npmjs.org`              | 443  | `npm install` for `web-app/`                                                                                                     |
| `registry-1.docker.io`            | 443  | Docker Hub — base images (`python:3.12-slim`, `node:20-alpine`, `nginx:alpine`)                                                  |
| `auth.docker.io`                  | 443  | Docker Hub auth                                                                                                                  |
| `production.cloudflare.docker.com`| 443  | Docker Hub CDN                                                                                                                   |
| `pypi.org`, `files.pythonhosted.org`| 443| Python wheels for `api-app/requirements.txt` (FastAPI, OpenAI SDK, MS Agent Framework, etc.)                                     |
| `objects.githubusercontent.com`   | 443  | GitHub raw asset fetches (Bicep templates etc.)                                                                                  |
| `github.com`                      | 443  | Clone repository, version metadata                                                                                               |
| `release-assets.githubusercontent.com` | 443 | Bicep release binaries (used by `az bicep`)                                                                                  |

> If InvestCorp uses an internal mirror (Artifactory / Nexus / MS Container Registry replica), substitute those instead — the Dockerfiles accept registry overrides.

#### D. Optional (only if using Bastion for ad-hoc admin)

| Destination                           | Port  | Purpose                            |
| ------------------------------------- | ----- | ---------------------------------- |
| `portal.azure.com`                    | 443   | Azure Portal Bastion connect page  |
| `*.bastionglobal.azure.com`           | 443   | Bastion data plane                 |
| `bastion.azure.com`                   | 443/22/3389 | Bastion control plane         |

---

## 6. Temporary changes required during bootstrap

The zero-trust template intentionally locks every data plane down. To **first** push application images & grant the operator privileges, a small number of **temporary** changes are needed. Each one MUST be reverted before go-live.

### 6.1 Grant the operator AAD identity `AcrPush` on the ACR

The template only grants `AcrPull` to the workload UAMI. The human (or service principal) running `infra/2-build-and-push-images.sh` needs **`AcrPush`** (and ideally `AcrDelete`) on the new ACR.

```bash
ME=$(az ad signed-in-user show --query id -o tsv)
ACR_ID=$(az acr show -n <acr-name> -g <rg> --query id -o tsv)
az role assignment create --assignee-object-id $ME --assignee-principal-type User \
  --role AcrPush --scope $ACR_ID
```

If the operator is a service principal (CI/CD), grant the SP instead.

**Revert**: optional. Many customers leave `AcrPush` in place for the deployment SP/group. Remove with `az role assignment delete`.

### 6.2 Temporarily enable ACR public network access (only if operator is NOT yet peered)

If your operator workstation cannot yet reach `<acr>.azurecr.io` over peering (e.g., on Day 1 before the ExpressRoute is configured), you must briefly open ACR. **Two extra hardening flags must be flipped first**:

```bash
ACR=<acr-name>
RG=<rg>
SUB=$(az account show --query id -o tsv)
TOKEN=$(az account get-access-token --query accessToken -o tsv)

# 1. Enable exportPolicy (default is 'disabled' in this template; required before flipping public access)
curl -sS -X PATCH \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR?api-version=2023-07-01" \
  -d '{"properties":{"policies":{"exportPolicy":{"status":"enabled"}}}}'

# 2. Enable public network access with default-Allow
az acr update -n $ACR -g $RG --public-network-enabled true --default-action Allow

# … run script 2 …

# 3. RESTORE
az acr update -n $ACR -g $RG --public-network-enabled false
# Optional: reapply exportPolicy=disabled via the same PATCH with status: "disabled"
```

> **If the operator IS peered**, skip this entirely — keep `publicNetworkAccess=Disabled` and push over peering.

### 6.3 Optional: harden AI Foundry post-deploy

The Bicep currently provisions the Foundry account with `publicNetworkAccess=Enabled` + `networkAcls.defaultAction=Deny` + a VNet rule for `snet-services`. Some customers (typically Financial Services) prefer to also flip the master switch off. After `script 3` finishes:

```bash
az cognitiveservices account update -g <rg> -n <foundry-account> \
  --public-network-access Disabled
```

The Private Endpoint on `services.ai.azure.com` already exists, so apps continue to work.

### 6.4 Operator workstation needs internet egress for bootstrap supply chain

See §5.2 group C. If the operator is on a fully air-gapped corporate network, mirror those URLs internally before running script 2 (recommended for production InvestCorp deployments).

### 6.5 ARM deployment-name search (resolved)

Earlier revisions of `infra/1-deploy-azure-infra.sh` and `infra/3-deploy-apps.sh` looked for two different ARM deployment names (`ai-invest-sample-<ts>` vs `ai-invest-appsvc`). This is **resolved** in the current main branch: script 3 now searches for `ai-invest-sample`. No manual patching required.

---

## 7. RBAC summary

| Principal                              | Role                                            | Scope                       | Provisioned by    |
| -------------------------------------- | ----------------------------------------------- | --------------------------- | ----------------- |
| UAMI (workload identity)               | `AcrPull`, `AcrPush`, `AcrDelete`               | ACR                         | Bicep             |
| UAMI                                   | `Storage Blob Data Contributor`                 | Storage account             | Bicep             |
| UAMI                                   | `Cosmos DB Built-in Data Contributor`           | Cosmos account              | Bicep             |
| UAMI                                   | `Azure AI User`                                 | AI Foundry account          | Bicep             |
| Deployer (running scripts)             | `Cosmos DB Built-in Data Contributor`           | Cosmos account              | Bicep             |
| Deployer (running scripts)             | `Contributor` (or `Owner`)                      | Resource group              | Customer (manual) |
| **Operator running script 2**          | **`AcrPush`** (`AcrDelete` optional)            | **ACR**                     | **Manual (§6.1)** |

---

## 8. Step-by-step deployment runbook for InvestCorp

> **Pre-req**: Customer has chosen a `/26` CIDR, a region, peering is up, the operator workstation can reach Microsoft control plane + (during bootstrap) the supply-chain URLs in §5.2 C.

```bash
# 0. Clone the template
git clone https://github.com/Azure-Samples/Agentic-AI-Investment-Analysis-Sample.git
cd Agentic-AI-Investment-Analysis-Sample
git checkout main  # or release tag

# 1. Log in & set subscription
az login --tenant <investcorp-tenant>
az account set --subscription <investcorp-sub>

# 2. Create RG (or have customer pre-create)
LOC=swedencentral   # or uaenorth
RG=rg-investcorp-aiinvest-prod
az group create -n $RG -l $LOC

# 3. Deploy infra
bash infra/1-deploy-azure-infra.sh \
  -g $RG \
  -l $LOC \
  --name-prefix invstcrp \
  --environment prod \
  --is-private true \
  --vnet-address-prefix 10.123.45.0/26     # supplied by InvestCorp network team

# 4. Grant operator AcrPush (see §6.1)
ME=$(az ad signed-in-user show --query id -o tsv)
ACR=$(az acr list -g $RG --query "[0].name" -o tsv)
ACR_ID=$(az acr show -n $ACR -g $RG --query id -o tsv)
az role assignment create --assignee-object-id $ME --assignee-principal-type User \
  --role AcrPush --scope $ACR_ID

# 5. (only if NOT yet peered) Temporarily open ACR — see §6.2
# … skip if peered …

# 6. Build & push images
bash infra/2-build-and-push-images.sh -r $ACR.azurecr.io --docker
# (use --acr instead for ACR Tasks — requires VNet-enabled agent pool)

# 7. Re-lock ACR (if you opened it in step 5)
az acr update -n $ACR -g $RG --public-network-enabled false

# 8. Deploy apps
yes | bash infra/3-deploy-apps.sh -g $RG -p invstcrp -e prod -t latest

# 9. (recommended) Harden AI Foundry — see §6.3
FOUNDRY=$(az cognitiveservices account list -g $RG --query "[0].name" -o tsv)
az cognitiveservices account update -g $RG -n $FOUNDRY --public-network-access Disabled
```

---

## 9. Post-deploy verification

Run from a workstation **peered** to the workload VNet (i.e. a VM in the InvestCorp hub):

```powershell
# DNS must resolve to private IPs (10.x range)
'<api-host>.azurewebsites.net',
'<web-host>.azurewebsites.net',
'<acr>.azurecr.io',
'<cosmos>.documents.azure.com',
'<storage>.blob.core.windows.net' | ForEach-Object {
    $r = Resolve-DnsName $_ -Type A -ErrorAction SilentlyContinue | Select-Object -First 1
    $tc = Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue
    "{0,-65} IP={1} TCP443={2}" -f $_, $r.IPAddress, $tc.TcpTestSucceeded
}

# Apps must return HTTP 200 over PE
Invoke-WebRequest "https://<api-host>.azurewebsites.net/health" -UseBasicParsing
Invoke-WebRequest "https://<web-host>.azurewebsites.net/" -UseBasicParsing
```

From the **internet** (i.e. not peered) the same hosts must return `HTTP 403` / connection-blocked. This is the proof of zero-trust.

---

## 10. Decommissioning

```bash
# Whole environment
az group delete -g rg-investcorp-aiinvest-prod --yes --no-wait

# Or just stop compute + keep data
az webapp stop -g rg-investcorp-aiinvest-prod -n invstcrp-api-prod
az webapp stop -g rg-investcorp-aiinvest-prod -n invstcrp-web-prod
```

---

## 11. Validation evidence (May 2026 demo deployment)

Deployment was validated against `MCAPS-Hybrid-AI&HPC-Saad` / `swedencentral` with `investcorpEnv=true`. The template does **not** provision a Bastion, jumpbox, or any VM — operator commands were issued from the local workstation using the temporary public-access exceptions documented in Appendix D, then reverted.

| Check                                                                       | Result                                                                |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `az bicep build` (only BCP318 warnings, no errors)                          | ✅                                                                    |
| `1-deploy-azure-infra.sh` with `--parameters-file ...investcorp...`         | ✅ `Succeeded`                                                        |
| IVC invariants: 0 NSGs, 0 private DNS zones, 0 private endpoints in the RG  | ✅ (proves customer-managed networking left intact)                   |
| All 13 customer-requested resource names applied (11 by bicepparam + 2 by script 3) | ✅                                                                    |
| `2-build-and-push-images.sh --acr` (ACR Tasks, no local Docker)             | ✅ `ai-invest-api:latest` + `ai-invest-web:latest` pushed             |
| `3-deploy-apps.sh --api-app-name ... --web-app-name ...`                    | ✅ both Web Apps deployed with the IVC names                          |
| `curl /health` against API (after temp `publicNetworkAccess=Enabled`)       | ✅ HTTP 200                                                           |
| `curl /` against Web (after temp `publicNetworkAccess=Enabled`)             | ✅ HTTP 200                                                           |
| Apps from public internet **after revert** (`publicNetworkAccess=Disabled`) | ✅ HTTP 403 (blocked — only the customer's PEs are reachable)         |

---

## 12. Custom naming convention (InvestCorp CAF)

> **InvestCorp naming standard — what was applied in the validated deployment**
>
> The customer's naming team supplied an exact name for each resource. Some of those names had to be adjusted to satisfy hard Azure / AVM constraints; every adjustment is called out in the *Adjustment* column below. The values shown here are the same ones used in `infra/bicep/main.investcorp.example.bicepparam` and validated end-to-end (see Appendix D).
>
> **Pattern (logical):** `<workload>-<env>-<service>-<region>-<instance>` for hyphenated services, and `<svc><env><workload><region><instance>` (no separators) for resources that disallow `-` (storage, ACR). `partnerfirms` is the InvestCorp workload code. `eus2` was the original region tag — keep this tag stable even if the deployment region changes (it is a label, not a region lookup).
>
> **Required override flag:** every name is supplied via the matching `*NameOverride` parameter (see Option B table below). If you skip an override, the deployer falls back to the hash-based default in Option A.

| #  | Resource                          | Customer-requested name                              | Adjustment (if any)                                                                                       | Override parameter                     |
| -- | --------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1  | Virtual Network                   | `vnet-dev-aifoundry-eus2-01`                         | —                                                                                                         | `vnetNameOverride`                     |
| 2  | User-Assigned Managed Identity    | `partnerfirms-dev-mngdid-01`                         | —                                                                                                         | `userAssignedIdentityNameOverride`     |
| 3  | Log Analytics Workspace           | `log-analytics-ws-dev-partnerfirms-eus2-01`          | —                                                                                                         | `logAnalyticsWorkspaceNameOverride`    |
| 4  | Application Insights              | `appinsights-app-dev-ivc-aifoundry-partnerfirms`     | —                                                                                                         | `appInsightsNameOverride`              |
| 5  | AMPLS (Monitor Private Link Scope)| `az-monitor-pls-partnerfirms-eus2-01`                | —                                                                                                         | `amplsNameOverride`                    |
| 6  | Storage Account                   | `strgdevpartnerfirmseus20`                           | **Trimmed from `strgdevpartnerfirmseus201` (25 chars) to `strgdevpartnerfirmseus20` (24 chars max).** Confirm with customer naming team before prod. | `storageAccountNameOverride`           |
| 7  | Cosmos DB Account                 | `cosmosdb-dev-partnerfirms-ne-01`                    | —                                                                                                         | `cosmosAccountNameOverride`            |
| 8  | Azure Container Registry          | `regpartnerfirmseus201`                              | —                                                                                                         | `containerRegistryNameOverride`        |
| 9  | App Service Plan                  | `asp-app-dev-ivc-aifoundry-partnerfirms`             | —                                                                                                         | `appServicePlanNameOverride`           |
| 10 | AI Foundry account (base)         | `aifoundrypf`                                        | **AVM `baseName` is capped at 12 chars.** The full preferred name (`aifoundry-dev-partnerfirms-eus2-01`) cannot fit. `pf` = partnerfirms. | `aiFoundryBaseNameOverride`            |
| 11 | AI Foundry project                | `aiivcpartnerfirms-project`                          | —                                                                                                         | `aiFoundryProjectNameOverride`         |
| 12 | API App Service                   | `app-dev-ivc-aifoundry-partnerfirms-01`              | Set at Phase 3 (Web Apps are deployed by `3-deploy-apps.sh`, not by `main.bicep`)                          | `--api-app-name` flag (script 3)       |
| 13 | Web App Service                   | `app-dev-ivc-aifoundry-partnerfirms-02`              | Same — Phase 3                                                                                            | `--web-app-name` flag (script 3)       |

### 12.1 Hard naming constraints to know before you submit names

| Resource          | Length      | Allowed chars                          | Scope of uniqueness          |
| ----------------- | ----------- | -------------------------------------- | ---------------------------- |
| Storage account   | **3–24**    | lowercase a-z + 0-9 only (no `-`/`_`)  | **Global**                   |
| Container Registry| 5–50        | a-z A-Z 0-9 only (no `-`/`_`)          | **Global**                   |
| Cosmos DB account | 3–44        | a-z 0-9 `-`                            | **Global**                   |
| AI Foundry baseName| **≤ 12**   | lowercase a-z 0-9 (AVM module limit)   | Per-region uniqueness OK     |
| Key Vault (n/a here)| 3–24       | a-z A-Z 0-9 `-`                        | Global                       |
| Virtual Network   | 2–64        | a-z A-Z 0-9 `-` `_` `.`                | Per-resource-group           |
| UAMI              | 3–128       | a-z A-Z 0-9 `-` `_`                    | Per-resource-group           |
| Log Analytics WS  | 4–63        | a-z A-Z 0-9 `-`                        | Per-resource-group           |
| App Insights      | 1–260       | most chars                             | Per-resource-group           |
| AMPLS             | 1–255       | most chars                             | Per-resource-group           |
| App Service Plan  | 1–40        | a-z A-Z 0-9 `-`                        | Per-resource-group           |
| Web App           | 2–60        | a-z A-Z 0-9 `-` (not starting/ending with `-`) | **Global** (DNS)     |

The template supports two ways to control resource names. Pick one:

### Option A — keep the default pattern, just change the prefix

Every resource is named `<namePrefix>-<kind>-<hash>` (e.g. `invstdemo-cosmosdb-uqyihrdx2wrsa`). Pass your own prefix:

```bash
bash infra/1-deploy-azure-infra.sh -g $RG -l $LOC --name-prefix invscrp --is-private true --vnet-address-prefix 10.123.45.0/26
```

You get `invscrp-vnet-…`, `invscrp-cosmosdb-…`, `invscrpacr…`, etc. **The 8-char hash is non-negotiable in this mode** because it guarantees global uniqueness for storage / ACR / Cosmos / Foundry.

### Option B — supply exact resource names (full CAF override)

`main.bicep` accepts one optional `*NameOverride` parameter per resource. Anything left empty falls back to Option A. Supply only the ones you need to control.

| Parameter                            | Resource                       | Azure naming constraints                       |
| ------------------------------------ | ------------------------------ | ---------------------------------------------- |
| `vnetNameOverride`                   | Virtual Network                | 2-64 alphanumerics + `-`, `_`, `.`             |
| `userAssignedIdentityNameOverride`   | UAMI                           | 3-128 alphanumerics + `-`, `_`                 |
| `logAnalyticsWorkspaceNameOverride`  | Log Analytics workspace        | 4-63 alphanumerics + `-`                       |
| `appInsightsNameOverride`            | Application Insights           | 1-260 alphanumerics + most chars               |
| `amplsNameOverride`                  | Azure Monitor Private Link Scope | 1-255                                        |
| `storageAccountNameOverride`         | Storage account                | **3-24 lowercase alphanumerics, globally unique** |
| `cosmosAccountNameOverride`          | Cosmos DB account              | **3-44 lowercase alphanumerics + `-`, globally unique** |
| `containerRegistryNameOverride`      | Azure Container Registry       | **5-50 alphanumerics, globally unique**        |
| `appServicePlanNameOverride`         | App Service Plan               | 1-40 alphanumerics + `-`                       |
| `aiFoundryBaseNameOverride`          | AI Foundry account base name   | **≤ 12 lowercase alphanumerics** (suffix base) |
| `aiFoundryProjectNameOverride`       | AI Foundry project             | 2-32 alphanumerics + `-` (default `aiinvest-project`) |
| `investcorpEnv`                      | Toggle managed-network mode    | `bool`, see §12.3                              |

A worked example is provided in [`infra/bicep/main.investcorp.example.bicepparam`](../infra/bicep/main.investcorp.example.bicepparam):

```bicepparam
using './main.bicep'

param isPrivate = true
param investcorpEnv = true                       // IVC mode (see §12.3)
param vnetAddressPrefix = '10.123.45.0/26'
param environment = 'dev'
param namePrefix = 'invstdemo'

param vnetNameOverride                  = 'vnet-dev-aifoundry-eus2-01'
param userAssignedIdentityNameOverride  = 'partnerfirms-dev-mngdid-01'
param logAnalyticsWorkspaceNameOverride = 'log-analytics-ws-dev-partnerfirms-eus2-01'
param appInsightsNameOverride           = 'appinsights-app-dev-ivc-aifoundry-partnerfirms'
param amplsNameOverride                 = 'az-monitor-pls-partnerfirms-eus2-01'
param storageAccountNameOverride        = 'strgdevpartnerfirmseus20'              // 24-char max
param cosmosAccountNameOverride         = 'cosmosdb-dev-partnerfirms-ne-01'
param containerRegistryNameOverride     = 'regpartnerfirmseus201'
param appServicePlanNameOverride        = 'asp-app-dev-ivc-aifoundry-partnerfirms'
param aiFoundryBaseNameOverride         = 'aifoundrypf'                           // 12-char AVM limit
param aiFoundryProjectNameOverride      = 'aiivcpartnerfirms-project'
```

Deploy with:

```bash
./infra/1-deploy-azure-infra.sh \
  -g $RG \
  -l eastus2 \
  --parameters-file infra/bicep/main.investcorp.example.bicepparam
```

> **Caller is responsible** for the naming rules listed above (storage/ACR/Cosmos in particular). If a name violates Azure rules or is already taken globally, the deployment will fail with a clear error from the resource provider.

### 12.3 `investcorpEnv=true` — customer-managed networking mode

InvestCorp's network team owns NSGs, private endpoints, and the hub-managed `privatelink.*` DNS zones. Setting `investcorpEnv=true` puts the template into "managed-network" mode that aligns with their standard:

| Concern                          | Default (`investcorpEnv=false`)                  | InvestCorp mode (`investcorpEnv=true`)                                    |
| -------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------- |
| NSGs (`-nsg-pe`, `-nsg-services`)| Created and attached to subnets                  | **Not created.** Subnets deployed without NSG (Azure Firewall + intra-VNet rules cover policy) |
| Private DNS zones (12 × `privatelink.*`) | Created in the workload RG and linked to VNet | **Not created.** Customer's hub already hosts these zones                |
| Private endpoints (PaaS + apps)  | Created in `snet-pe` and joined to local DNS zones | **Not created.** Customer's network team creates PEs and adds the A-records in their hub DNS zones post-deploy |
| `publicNetworkAccess` on PaaS    | `Disabled` (zero-trust)                          | **Still `Disabled`** — resources stay private until the customer wires their PEs |
| AMPLS resource                   | Created with PE                                  | Created **without** PE (customer adds PE manually)                        |
| AI Foundry networking            | AVM creates PEs and DNS zone groups              | AVM `networking` block omitted — customer creates PEs against their DNS zones |
| VNet + subnets (`snet-services`, `snet-pe`) | Created                              | **Still created** (workload owns the VNet)                                |
| Bastion / jumpbox / Public IPs   | Never deployed                                   | Never deployed                                                            |

When this flag is on, the customer's network team must complete the following **after** `1-deploy-azure-infra.sh` succeeds and **before** `3-deploy-apps.sh` runs (since the apps need ACR pull over the PE):

1. Create Private Endpoints for: Storage (blob), Cosmos (Sql), ACR (registry), AMPLS (azuremonitor), AI Foundry (account + each model), `snet-pe`.
2. Add the A-records into the corresponding `privatelink.*` zone in the IVC hub (e.g. `privatelink.azurecr.io` → `<acr-name>.privatelink.azurecr.io`).
3. Create Private Endpoints for the API and Web Apps **after** `3-deploy-apps.sh` finishes (the App Service resources exist only after Phase 3).

The flag requires `isPrivate=true` (default). Validate the build:

```bash
az bicep build-params --file infra/bicep/main.investcorp.example.bicepparam --stdout > /dev/null
```

### 12.2 App Service (api/web) names

The two Web App names are generated by `infra/3-deploy-apps.sh` as `<name-prefix>-api-<env>` and `<name-prefix>-web-<env>`. Pass the InvestCorp values directly via the new `--api-app-name` / `--web-app-name` flags (or the matching env vars):

```bash
./infra/3-deploy-apps.sh -g $RG \
  --api-app-name app-dev-ivc-aifoundry-partnerfirms-01 \
  --web-app-name app-dev-ivc-aifoundry-partnerfirms-02
```

(If a fully CAF-compliant pattern such as `invs-aiinv-prod-bhc-web-001` is required, edit `var appName` in `api-app/infra/bicep/main.bicep` and `web-app/infra/bicep/main.bicep` — these are simple one-liners; a future PR will expose them as parameters too.)

### Resource group + region

These are caller-controlled, not template-controlled:

```bash
az group create -n rg-invs-aiinv-prod-bhc-001 -l uaenorth
```

---

## 13. Hand-off checklist for InvestCorp networking team

- [ ] Confirm `/26` CIDR allocated and recorded in IPAM
- [ ] VNet peering created in both directions; `allow-forwarded-traffic` enabled if hub is hub-and-spoke
- [ ] Hub DNS forwards `privatelink.*` to `168.63.129.16` (or zones are also linked to hub VNet)
- [ ] Operator workstation can reach Microsoft control plane (§5.2 A)
- [ ] Operator workstation has bootstrap supply-chain access OR internal mirrors configured (§5.2 C)
- [ ] `AcrPush` granted on ACR to the human/SP running script 2 (§6.1)
- [ ] After go-live, AI Foundry flipped to `publicNetworkAccess=Disabled` (§6.3)
- [ ] Optional: Bastion Basic deployed in the hub for emergency admin (§5.2 D)
- [ ] Backup & DR strategy for Cosmos (`Continuous7Days` enabled), Storage (consider GRS for prod), ACR (`georeplications` for prod)

---

## Appendix D. Live end-to-end walkthrough (19 May 2026)

This appendix is a **verbatim playbook** of the validation run performed against the `MCAPS-Hybrid-AI&HPC-Saad` subscription in `swedencentral`. Every command, every prompt, every Azure-side configuration change, and every defect discovered during the run is captured here so the InvestCorp operator can reproduce the deployment with no ambiguity.

It supplements (does **not** replace) §6 "Day-1 deploy". When `investcorpEnv=true` the operator workstation only needs **outbound HTTPS to the Azure control plane** — every command below is `az` / `curl`. No Docker required (we use **ACR Tasks** for the build).

### D.0 Pre-flight (one-time)

```bash
# 1) Repo at expected revision
cd /path/to/Agentic-AI-Investment-Analysis-Sample
git status                         # must be clean
git rev-parse HEAD                 # record commit SHA for change ticket

# 2) Logged into the right tenant + subscription
az login                           # interactive; SSO is fine
az account set --subscription '<subscription-name-or-id>'
az account show --query '{name:name, id:id, tenantId:tenantId}' -o table

# 3) CLI versions (anything ≥ these works)
az version
#   azure-cli      2.60+
#   bicep          0.30+   (deploy script auto-uses az bicep)
```

### D.1 Resource group

```bash
# Variables used throughout
RG=rg-aiinvest-ivc-test
LOC=swedencentral

az group exists --name "$RG"                                # -> false
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags Project=ai-investment-analysis-sample \
         Owner=<your-alias> \
         Mode=investcorpEnv \
  -o table
# Location      Name
# ------------  --------------------
# swedencentral rg-aiinvest-ivc-test
```

### D.2 Phase 1 — infrastructure (`investcorpEnv=true`)

The IVC parameter file lives at `infra/bicep/main.investcorp.example.bicepparam`. Copy it to a customer-specific file (e.g. `main.investcorp.bicepparam`) and edit the names — do **not** check secrets in. For the validation we used the example file as-is.

```bash
# The script auto-confirms one prompt ("Continue with deployment? (y/N)"),
# so we pipe `yes y` to be non-interactive.
yes y | ./infra/1-deploy-azure-infra.sh \
  -g "$RG" \
  -l "$LOC" \
  --parameters-file infra/bicep/main.investcorp.example.bicepparam \
  2>&1 | tee /tmp/ivc-infra-deploy.log
```

Validated runtime: **~13 minutes**. Expected stdout tail:

```text
Name                         State      Timestamp                         Mode         ResourceGroup
---------------------------  ---------  --------------------------------  -----------  --------------------
ai-invest-sample-1779198411  Succeeded  2026-05-19T13:51:27.728528+00:00  Incremental  rg-aiinvest-ivc-test
✅ Infrastructure deployed successfully
Container Registry: regpartnerfirmseus201.azurecr.io
🎉 Azure infrastructure deployment completed!
```

> **BCP318 warnings** during `az bicep build` are expected and harmless. They originate from optional modules (`privateDns`, NSGs) that may be `null` in IVC mode. The deployment is unaffected because every consumer guards with `(isPrivate && !investcorpEnv)`.

### D.3 Phase 1 — invariants check (proves IVC mode actually skipped NSG/PE/DNS)

```bash
# Full resource list (should be exactly 11 entries — no NSG, no PE, no DNS zone)
az resource list -g "$RG" --query "[].{name:name, type:type}" -o table
```

Expected:

```text
Name
----------------------------------------------
asp-app-dev-ivc-aifoundry-partnerfirms                       Microsoft.Web/serverFarms
vnet-dev-aifoundry-eus2-01                                   Microsoft.Network/virtualNetworks
partnerfirms-dev-mngdid-01                                   Microsoft.ManagedIdentity/userAssignedIdentities
log-analytics-ws-dev-partnerfirms-eus2-01                    Microsoft.OperationalInsights/workspaces
regpartnerfirmseus201                                        Microsoft.ContainerRegistry/registries
cosmosdb-dev-partnerfirms-ne-01                              Microsoft.DocumentDB/databaseAccounts
strgdevpartnerfirmseus20                                     Microsoft.Storage/storageAccounts
aiaifoundrypfqxpzh                                           Microsoft.CognitiveServices/accounts
appinsights-app-dev-ivc-aifoundry-partnerfirms               Microsoft.Insights/components
aiaifoundrypfqxpzh/aiivcpartnerfirms-project                 Microsoft.CognitiveServices/accounts/projects
az-monitor-pls-partnerfirms-eus2-01                          Microsoft.Insights/privateLinkScopes
```

Hard gate — must return **0**:

```bash
az resource list -g "$RG" --query "[?contains(type,'networkSecurityGroups') \
  || contains(type,'privateDnsZones') \
  || contains(type,'privateEndpoints')] | length(@)" -o tsv
# 0
```

If non-zero, the IVC flag did not propagate. Inspect `infra/bicep/main.bicep` lines around `privateDns` / `network` modules and re-deploy.

### D.4 Phase 1 → Phase 2 — temporary network exceptions

When the IVC hub PEs are not in place yet (smoke-test scenario), we open the PaaS plane briefly so the operator workstation can push images and the App Service can reach Cosmos / Storage. **These five commands MUST be reverted before handing the env to InvestCorp** (see §D.10).

#### D.4.1 Container Registry

The Bicep configures ACR with `exportPolicy.status=Disabled` to prevent data egress. Azure rejects `publicNetworkAccess=Enabled` while exports are disabled, so we flip exports first:

```bash
az acr update -n regpartnerfirmseus201 --allow-exports true \
  -o tsv --query "policies.exportPolicy.status"
# enabled

az acr update -n regpartnerfirmseus201 --public-network-enabled true \
  -o tsv --query "publicNetworkAccess"
# Enabled
```

Grant **AcrPush** to the human running the build (the AVM module already gives **AcrPull** to the UAMI):

```bash
SUB=$(az account show --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role AcrPush \
  --scope "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/regpartnerfirmseus201" \
  --query principalId -o tsv
```

#### D.4.2 Cosmos DB

```bash
az cosmosdb update \
  -g "$RG" -n cosmosdb-dev-partnerfirms-ne-01 \
  --public-network-access Enabled \
  --only-show-errors \
  -o tsv --query "publicNetworkAccess"
# Enabled
```

> `--enable-public-network` is **not** a valid flag on `az cosmosdb update`. Use `--public-network-access Enabled` (case-sensitive). The control-plane operation can take 30-120s; subsequent updates against the same account will fail with `PreconditionFailed` until it completes.

#### D.4.3 Storage account

```bash
az storage account update \
  -g "$RG" -n strgdevpartnerfirmseus20 \
  --public-network-access Enabled \
  -o tsv --query "publicNetworkAccess"
# Enabled
```

> **GOTCHA — discovered during this run.** The Bicep also sets `networkAcls.defaultAction=Deny` when `isPrivate=true`. Even with `publicNetworkAccess=Enabled`, **all** traffic is dropped because the firewall default is Deny and there is no VNet rule for `snet-services`. Symptom: the API container starts, then crashes with `AuthorizationFailure` from `azure.storage.blob`, App Service responds `HTTP 503`.
>
> **Permanent fix already applied** (commit on this branch): when `investcorpEnv=true`, `networkAcls.defaultAction` is set to `Allow`. `publicNetworkAccess` remains `Disabled` in the final state, so the customer's PE is still the only reachable path. See `infra/bicep/modules/storage.bicep` and the `investcorpEnv` param plumbed from `main.bicep`.
>
> If you are on an older revision of the template, apply the workaround manually:
>
> ```bash
> az storage account update \
>   -g "$RG" -n strgdevpartnerfirmseus20 \
>   --default-action Allow \
>   -o tsv --query "networkRuleSet.defaultAction"
> # Allow
> ```

### D.5 Phase 2 — build & push images (ACR Tasks, no local Docker)

`infra/2-build-and-push-images.sh` supports two modes:

| Flag | Where build runs | Requires Docker locally? |
| --- | --- | --- |
| `--docker` *(default)* | Operator workstation | Yes — fails fast if Docker daemon not reachable |
| `--acr` | Azure-side (ACR Tasks) | **No** — ideal for locked-down workstations |

For IVC operators we strongly recommend `--acr`:

```bash
yes y | ./infra/2-build-and-push-images.sh \
  -r regpartnerfirmseus201.azurecr.io \
  --acr \
  2>&1 | tee /tmp/ivc-images.log
```

Validated runtime: **~10-15 minutes for both images**. The script makes 3 attempts per image to handle Docker Hub `toomanyrequests` (rate-limit) errors. Expected final lines:

```text
✅ Successfully built and pushed regpartnerfirmseus201.azurecr.io/ai-invest-api:latest via ACR Tasks
✅ Successfully built and pushed regpartnerfirmseus201.azurecr.io/ai-invest-web:latest via ACR Tasks
🎉 Image(s) built and pushed successfully!
```

### D.6 Phase 3 — application deploy with explicit IVC names

```bash
yes y | ./infra/3-deploy-apps.sh \
  -g "$RG" \
  --api-app-name app-dev-ivc-aifoundry-partnerfirms-01 \
  --web-app-name app-dev-ivc-aifoundry-partnerfirms-02 \
  2>&1 | tee /tmp/ivc-apps-deploy.log
```

Validated runtime: **~10-15 minutes**. Expected final lines:

```text
✅ API App: https://app-dev-ivc-aifoundry-partnerfirms-01.azurewebsites.net
   Health Check: https://app-dev-ivc-aifoundry-partnerfirms-01.azurewebsites.net/health
   API Docs: https://app-dev-ivc-aifoundry-partnerfirms-01.azurewebsites.net/docs
✅ Web App: https://app-dev-ivc-aifoundry-partnerfirms-02.azurewebsites.net
```

### D.7 Phase 3.5 — temporarily open App Service public access (smoke-test only)

Both Web Apps inherit `publicNetworkAccess=Disabled` from the private template. To smoke-test from the operator workstation:

```bash
az webapp update -g "$RG" -n app-dev-ivc-aifoundry-partnerfirms-01 \
  --set publicNetworkAccess=Enabled --query "name" -o tsv
az webapp update -g "$RG" -n app-dev-ivc-aifoundry-partnerfirms-02 \
  --set publicNetworkAccess=Enabled --query "name" -o tsv
```

### D.8 Phase 3.6 — smoke test

```bash
curl -sS -o /dev/null -w "%{http_code}\n" --max-time 30 \
  https://app-dev-ivc-aifoundry-partnerfirms-01.azurewebsites.net/health
# 200

curl -sS -o /dev/null -w "%{http_code}\n" --max-time 30 \
  https://app-dev-ivc-aifoundry-partnerfirms-02.azurewebsites.net/
# 200
```

If the **API returns 503** for >2 minutes after the deploy:

1. Confirm the image listens on port **8090** — the Dockerfile is `CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090"]`. App Service Linux needs `WEBSITES_PORT=8090`. The Bicep sets this automatically via `web-app-container.bicep` (`targetPort=8090`).
2. Pull container logs:

   ```bash
   az webapp log download -g "$RG" -n app-dev-ivc-aifoundry-partnerfirms-01 \
     --log-file /tmp/apilogs.zip
   rm -rf /tmp/apilogs && mkdir /tmp/apilogs
   unzip -q /tmp/apilogs.zip -d /tmp/apilogs
   tail -n 80 /tmp/apilogs/LogFiles/*default_docker.log
   ```
3. Common errors:
   - `AuthorizationFailure` on blob → §D.4.3 GOTCHA (storage firewall Deny).
   - `Forbidden` on Cosmos → §D.4.2 (Cosmos still has `publicNetworkAccess=Disabled`).
   - `did not start within expected time limit` → wrong `WEBSITES_PORT`.

### D.9 Phase 4 — operational checks

```bash
# Confirm UAMI role assignments on the data plane
UAMI_PID=$(az identity show -g "$RG" -n partnerfirms-dev-mngdid-01 --query principalId -o tsv)

STG_ID=$(az storage account show -g "$RG" -n strgdevpartnerfirmseus20 --query id -o tsv)
az role assignment list --assignee "$UAMI_PID" --scope "$STG_ID" \
  --query "[].{role:roleDefinitionName}" -o table
# Storage Blob Data Contributor + Contributor

ACR_ID=$(az acr show -n regpartnerfirmseus201 --query id -o tsv)
az role assignment list --assignee "$UAMI_PID" --scope "$ACR_ID" \
  --query "[].{role:roleDefinitionName}" -o table
# AcrPull
```

### D.10 Phase 5 — revert all temporary exceptions

**Mandatory before handing the env to the InvestCorp network team.** These commands restore the IVC-compliant posture so their PEs become the only reachable path:

```bash
# Re-disable public network access on every PaaS we opened
az acr update -n regpartnerfirmseus201 --public-network-enabled false \
  -o tsv --query "publicNetworkAccess"
# Disabled

# (Optional) Re-disable ACR exports if they were originally off
az acr update -n regpartnerfirmseus201 --allow-exports false \
  -o tsv --query "policies.exportPolicy.status"
# disabled

az cosmosdb update -g "$RG" -n cosmosdb-dev-partnerfirms-ne-01 \
  --public-network-access Disabled \
  -o tsv --query "publicNetworkAccess"
# Disabled

az storage account update -g "$RG" -n strgdevpartnerfirmseus20 \
  --public-network-access Disabled \
  -o tsv --query "publicNetworkAccess"
# Disabled

# App Services back to private
az webapp update -g "$RG" -n app-dev-ivc-aifoundry-partnerfirms-01 \
  --set publicNetworkAccess=Disabled --query "publicNetworkAccess" -o tsv
az webapp update -g "$RG" -n app-dev-ivc-aifoundry-partnerfirms-02 \
  --set publicNetworkAccess=Disabled --query "publicNetworkAccess" -o tsv
```

Final state sanity check:

```bash
az resource list -g "$RG" \
  --query "[?contains(type,'storageAccounts') || contains(type,'databaseAccounts') \
            || contains(type,'registries') || contains(type,'sites')] \
           .{name:name, public:properties.publicNetworkAccess}" \
  -o table
# All five should report 'Disabled'.
```

### D.11 Defects & template improvements landed during this validation

| # | Symptom found in run | Root cause | Fix shipped on this branch |
| - | -------------------- | ---------- | -------------------------- |
| 1 | API container `HTTP 503`; `AuthorizationFailure` from blob | `networkAcls.defaultAction=Deny` on storage, no VNet rule for `snet-services` in IVC mode | New `investcorpEnv` param on `modules/storage.bicep`; when true, `defaultAction=Allow` (publicNetworkAccess remains `Disabled` so PEs are still the only path) |
| 2 | `az acr update --public-network-enabled true` returned `BadRequest: exports disabled` | Bicep sets `exportPolicy.status=Disabled` | Documented the `--allow-exports true` prerequisite in §D.4.1 |
| 3 | First deploy attempt failed: `./infra/1-deploy-azure-infra.sh: No such file or directory` | Operator was in repo *parent* dir | Documented `cd` requirement / absolute path usage at top of §D.0 |
| 4 | `2-build-and-push-images.sh` fails with `Docker is not running` | Default mode is `--docker` | §D.5 mandates `--acr` for IVC operators |

### D.12 Full validated configuration matrix (post-revert)

| Resource | Name | publicNetworkAccess | Network ACL default | NSG attached | PE present | UAMI roles |
| --- | --- | --- | --- | --- | --- | --- |
| App Service Plan | `asp-app-dev-ivc-aifoundry-partnerfirms` | n/a | n/a | n/a | n/a | n/a |
| VNet | `vnet-dev-aifoundry-eus2-01` | n/a | n/a | **No** | n/a | n/a |
| UAMI | `partnerfirms-dev-mngdid-01` | n/a | n/a | n/a | n/a | n/a |
| LAW | `log-analytics-ws-dev-partnerfirms-eus2-01` | Disabled (ingestion via AMPLS) | n/a | n/a | Customer-managed | Reader (UAMI) |
| ACR | `regpartnerfirmseus201` | Disabled | n/a | n/a | Customer-managed | AcrPull (UAMI) |
| Cosmos DB | `cosmosdb-dev-partnerfirms-ne-01` | Disabled | n/a | n/a | Customer-managed | Cosmos DB Data Contributor (UAMI) |
| Storage | `strgdevpartnerfirmseus20` | Disabled | **Allow** (per IVC fix) | n/a | Customer-managed | Storage Blob Data Contributor + Contributor (UAMI) |
| AI Foundry | `aiaifoundrypfqxpzh` | Disabled (after §6.3) | Deny + `snet-services` VNet rule | n/a | Customer-managed | Azure AI Developer (UAMI) |
| AI Foundry project | `aiaifoundrypfqxpzh/aiivcpartnerfirms-project` | inherited | inherited | n/a | inherited | inherited |
| App Insights | `appinsights-app-dev-ivc-aifoundry-partnerfirms` | n/a | n/a | n/a | via AMPLS | n/a |
| AMPLS | `az-monitor-pls-partnerfirms-eus2-01` | n/a | `Open` for ingestion; `PrivateOnly` for queries | n/a | Customer-managed | n/a |
| API Web App | `app-dev-ivc-aifoundry-partnerfirms-01` | Disabled | n/a | n/a | Customer-managed | Uses UAMI |
| Web Web App | `app-dev-ivc-aifoundry-partnerfirms-02` | Disabled | n/a | n/a | Customer-managed | Uses UAMI |

### D.13 Total wall-clock budget (validated)

| Phase | Step | Duration |
| --- | --- | --- |
| D.1 | RG create | <10 s |
| D.2 | Infra deploy (script 1) | ~13 min |
| D.3 | Invariants check | <5 s |
| D.4 | Open temp exceptions (3× `az ... update` + 1 role assignment) | ~3 min |
| D.5 | Image build/push via ACR Tasks (2 images) | ~12 min |
| D.6 | App deploy (script 3) | ~12 min |
| D.7 | Open App Service public (smoke-only) | <30 s |
| D.8 | Smoke test | <10 s |
| D.10 | Revert all exceptions | ~3 min |
| **Total** | | **~45 min** |


