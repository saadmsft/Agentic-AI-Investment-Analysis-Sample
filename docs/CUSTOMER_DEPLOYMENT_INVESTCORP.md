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
| Validated end-to-end       | Yes — Mac (public) is `403`/blocked, peered VM (private) returns `HTTP 200` for both apps via PE                                                         |
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

### 6.5 Known repo issue to be aware of

The current `infra/1-deploy-azure-infra.sh` names its ARM deployment `ai-invest-sample-<timestamp>` but `infra/3-deploy-apps.sh` searches for `ai-invest-appsvc`. Two workarounds:

1. **Pre-flight**: rerun main.bicep manually with a name containing `ai-invest-appsvc`, e.g.
   `az deployment group create -g <rg> -n "ai-invest-appsvc-$(date +%s)" --template-file infra/bicep/main.bicep --parameters @<your.bicepparam>`
2. **Patch**: change the JMESPath query in `3-deploy-apps.sh` at line 163 to `[?contains(name, 'ai-invest-sample')].name | [0]`.

A fix will be raised upstream.

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

| Check                                              | Result                                                                |
| -------------------------------------------------- | --------------------------------------------------------------------- |
| Bicep template `what-if` (no errors, BCP318 warns) | ✅                                                                    |
| Workload deployment (`isPrivate=true`)             | ✅ `Succeeded`                                                        |
| Private DNS resolution from peered VM              | ✅ ACR=`10.123.45.50`, Cosmos=`10.123.45.52`, Storage=`10.123.45.51`  |
| TCP 443 to all PEs                                 | ✅ True                                                               |
| ACR `/v2/` over PE                                 | ✅ HTTP 401 (auth required)                                           |
| Apps via PE (`10.123.45.54` / `.55`)               | ✅ HTTP 200                                                           |
| Apps from public internet                          | ✅ HTTP 403 (blocked)                                                 |
| Mac (non-peered) to ACR / Storage                  | ✅ HTTP 403 (blocked)                                                 |

---

## 12. Custom naming convention (InvestCorp CAF)

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

A worked example is provided in [`infra/bicep/main.investcorp.example.bicepparam`](../infra/bicep/main.investcorp.example.bicepparam):

```bicepparam
using './main.bicep'

param isPrivate = true
param vnetAddressPrefix = '10.123.45.0/26'
param environment = 'prod'
param namePrefix = 'invscrp'

param vnetNameOverride               = 'invs-aiinv-prod-bhc-vnet-001'
param userAssignedIdentityNameOverride = 'invs-aiinv-prod-bhc-uami-001'
param logAnalyticsWorkspaceNameOverride = 'invs-aiinv-prod-bhc-law-001'
param appInsightsNameOverride        = 'invs-aiinv-prod-bhc-appi-001'
param amplsNameOverride              = 'invs-aiinv-prod-bhc-ampls-001'
param storageAccountNameOverride     = 'invsaiinvprodbhcst001'
param cosmosAccountNameOverride      = 'invs-aiinv-prod-bhc-cosmos-001'
param containerRegistryNameOverride  = 'invsaiinvprodbhcacr001'
param appServicePlanNameOverride     = 'invs-aiinv-prod-bhc-asp-001'
param aiFoundryBaseNameOverride      = 'invscaip01'
```

Deploy with:

```bash
az deployment group create -g $RG \
  --name "ai-invest-appsvc-$(date +%s)" \
  --template-file infra/bicep/main.bicep \
  --parameters infra/bicep/main.investcorp.example.bicepparam
```

> **Caller is responsible** for the naming rules listed above (storage/ACR/Cosmos in particular). If a name violates Azure rules or is already taken globally, the deployment will fail with a clear error from the resource provider.

### App Service (api/web) names

The two Web App names are generated by `infra/3-deploy-apps.sh` as `<name-prefix>-api-<env>` and `<name-prefix>-web-<env>`. Pass the InvestCorp values directly:

```bash
yes | bash infra/3-deploy-apps.sh -g $RG -p invs-aiinv -e prod -t latest
# → invs-aiinv-api-prod, invs-aiinv-web-prod
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

