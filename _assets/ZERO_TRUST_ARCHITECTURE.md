# Zero-Trust Architecture

End-to-end view of the Agentic AI Investment Analysis sample deployed with `isPrivate=true`. Every PaaS data plane is reached through a Private Endpoint inside a customer-owned VNet; there is no public DNS record for any workload. The only public surface is the Azure Bastion control-plane TLS endpoint used by operators.

## Logical view

```mermaid
flowchart LR
    classDef pub fill:#ffe0e0,stroke:#cc0000,color:#000
    classDef vnet fill:#e8f0ff,stroke:#1f4e9d,color:#000
    classDef pe fill:#fff4cc,stroke:#b58900,color:#000
    classDef app fill:#d6f5d6,stroke:#2e7d32,color:#000
    classDef data fill:#f0e6ff,stroke:#6a1b9a,color:#000
    classDef obs fill:#e0f7fa,stroke:#006064,color:#000
    classDef id fill:#fde7f3,stroke:#ad1457,color:#000

    Op([Operator / Developer]):::pub
    Internet([Public internet]):::pub

    subgraph RG[Azure Resource Group]
      subgraph VNet["VNet 10.50.0.0/16 (hub)"]
        direction TB
        subgraph S_Bastion[AzureBastionSubnet]
          Bastion[Azure Bastion<br/>Standard SKU<br/>*only* public IP]:::pub
        end
        subgraph S_Jump[snet-jumpbox]
          Jump[Windows jumpbox VM<br/>no public IP<br/>UAMI attached]:::vnet
        end
        subgraph S_Aca["snet-aca-infra (delegated)"]
          ACA[Container Apps Environment<br/>workload profiles · internal=true]:::app
          APIApp[API container app<br/>ingress: internal :8090]:::app
          WebApp[Web container app<br/>ingress: internal :8080]:::app
        end
        subgraph S_Pe[snet-pe]
          PE_Acr((PE · ACR)):::pe
          PE_Cos((PE · Cosmos)):::pe
          PE_Blob((PE · Blob)):::pe
          PE_Ai((PE · AI Foundry)):::pe
          PE_Ampls((PE · AMPLS)):::pe
          PE_Acs((PE · App Config<br/>optional)):::pe
        end
        subgraph S_Build[snet-build · reserved]
          Build[ACR Tasks / private build agents<br/>future use]:::vnet
        end
        subgraph S_Mgmt[snet-mgmt · reserved]
          Runner[Self-hosted CI/CD runner<br/>future use]:::vnet
        end
      end

      subgraph PaaS[Private PaaS · publicNetworkAccess = Disabled]
        ACR[Azure Container Registry<br/>Premium · admin disabled]:::data
        Cosmos[Cosmos DB<br/>disableLocalAuth=true]:::data
        Storage[Storage Account<br/>allowSharedKeyAccess=false]:::data
        AI[Azure AI Foundry<br/>+ OpenAI gpt-4.1-mini]:::data
        AppConfig[App Configuration<br/>optional]:::data
      end

      subgraph Obs[Observability via AMPLS]
        LA[Log Analytics<br/>ingestion/query private]:::obs
        AppI[Application Insights<br/>disableLocalAuth=true]:::obs
        AMPLS[Azure Monitor<br/>Private Link Scope]:::obs
      end

      subgraph Identity
        UAMI[User-Assigned Managed Identity<br/>AcrPull/Push · Storage Blob · Cosmos Data Contributor · RG Contributor]:::id
      end

      PDNS[(Private DNS Zones<br/>· documents.azure.com<br/>· blob.core.windows.net<br/>· azurecr.io<br/>· openai / cognitiveservices / services.ai<br/>· azconfig.io<br/>· monitor / oms / ods / agentsvc)]:::vnet
    end

    %% Operator path
    Op -- HTTPS 443 --> Bastion
    Bastion -- SSH via tunnel --> Jump
    Jump -- docker push / az deploy --> PE_Acr
    Jump -- browser tunnel --> WebApp

    %% App runtime path
    WebApp -- HTTP internal --> APIApp
    APIApp -- AAD token --> PE_Cos
    APIApp -- AAD token --> PE_Blob
    APIApp -- AAD token --> PE_Ai
    APIApp -- optional --> PE_Acs

    %% Private Endpoints map to PaaS
    PE_Acr -. private link .-> ACR
    PE_Cos -. private link .-> Cosmos
    PE_Blob -. private link .-> Storage
    PE_Ai -. private link .-> AI
    PE_Acs -. private link .-> AppConfig
    PE_Ampls -. private link .-> AMPLS
    AMPLS --- LA
    AMPLS --- AppI
    APIApp -. telemetry over AMPLS .-> PE_Ampls
    WebApp -. telemetry over AMPLS .-> PE_Ampls
    ACA -. logs .-> PE_Ampls

    %% DNS resolution
    Jump -. DNS .-> PDNS
    APIApp -. DNS .-> PDNS
    WebApp -. DNS .-> PDNS

    %% Identity attachments
    UAMI -. federated on .-> APIApp
    UAMI -. federated on .-> WebApp
    UAMI -. federated on .-> Jump

    %% Public boundary
    Internet -- blocked · no DNS --> ACR
    Internet -- blocked · no DNS --> Cosmos
    Internet -- blocked · no DNS --> Storage
    Internet -- blocked · no DNS --> AI
    Internet -- blocked · no DNS --> ACA
    Internet -- allowed only to --> Bastion
```

## Request paths

### Operator deploy flow
1. Operator opens browser → **Azure Bastion** (HTTPS 443, Azure-hosted TLS).
2. Bastion proxies RDP to the **Windows jumpbox VM** inside `snet-jumpbox`.
3. Jumpbox uses its UAMI to:
   - `docker push` to the private **ACR** via PE (`privatelink.azurecr.io`).
   - `az deployment group create` for the API / Web container app bicep.
4. Container Apps control plane validates + schedules revisions; image pull happens over the ACR private link.

### Application runtime flow
1. Operator tunnels browser traffic through Bastion to the **Web app**'s internal FQDN (`*.<env-id>.<region>.azurecontainerapps.io`, resolved to the ACA env's static IP via the auto-linked private DNS zone).
2. Web app calls the **API app** over the internal ACA ingress.
3. API app requests an Entra ID token via the mounted UAMI (`AZURE_CLIENT_ID`) and calls:
   - **Cosmos DB** → PE `Sql` · zone `privatelink.documents.azure.com`
   - **Storage blob** → PE `blob` · zone `privatelink.blob.<storage-suffix>`
   - **Azure OpenAI / AI Foundry** → PE `account` · zones `openai`, `cognitiveservices`, `services.ai`
4. Telemetry emits to App Insights / Log Analytics through the **AMPLS** private endpoint (`privatelink.monitor.azure.com` + `oms` + `ods` + `agentsvc`).

## Subnet layout

| Subnet | CIDR | Purpose |
|---|---|---|
| `snet-aca-infra` | /23 | Delegated to `Microsoft.App/environments` — ACA internal VNet integration |
| `snet-pe` | /26 | All Private Endpoints (ACR, Cosmos, Blob, AI Foundry, AMPLS, App Config) |
| `snet-jumpbox` | /27 | Jumpbox NIC (no public IP) |
| `AzureBastionSubnet` | /26 | Required name for Azure Bastion |
| `snet-build` | /27 | Reserved for ACR Tasks / private build agents |
| `snet-mgmt` | /27 | Reserved for self-hosted CI/CD runners |

## Zero-trust controls checklist

| Control | Enforced at |
|---|---|
| No public data-plane access | `publicNetworkAccess=Disabled` on Cosmos, Storage, ACR, AI Foundry, Log Analytics, App Insights, App Config |
| No shared-key / local auth | `allowSharedKeyAccess=false` (Storage), `disableLocalAuthentication=true` (Cosmos), `adminUserEnabled=false` (ACR), `disableLocalAuth=true` (LA, AppI, AI Foundry, App Config) |
| Managed-identity-only workload auth | UAMI with scoped AcrPull/Push, Storage Blob Data Contributor, Cosmos Data Contributor, Azure AI User, RG Contributor (jumpbox) |
| Internal app ingress | ACA env `internal=true`, both container apps `ingressExternal=false` |
| Restricted CORS | `ALLOW_ORIGINS` env-driven (no `*` in private mode) |
| Private DNS | All PaaS resolution via customer zones linked to the VNet |
| Telemetry isolation | App Insights + Log Analytics scoped to an AMPLS with `PrivateOnly` ingestion + query |
| NSGs | Per-subnet deny-by-default with explicit Bastion + PE 443 allow rules |
| Single public surface | Azure Bastion Standard — one public IP for operator access only |

## Dual-mode (`isPrivate` flag)

The same bicep can also deploy the original public demo topology by passing `isPrivate=false` to [`main.bicep`](../infra/bicep/main.bicep):

```mermaid
flowchart LR
    classDef pub fill:#ffe0e0,stroke:#cc0000,color:#000
    classDef app fill:#d6f5d6,stroke:#2e7d32,color:#000
    classDef data fill:#f0e6ff,stroke:#6a1b9a,color:#000

    Dev([Developer laptop]):::pub
    User([End user]):::pub

    subgraph PublicRG[Public demo mode]
      ACR[ACR · admin enabled]:::data
      ACAExt[Container Apps Env · external ingress]:::app
      API[API app · *.azurecontainerapps.io]:::app
      Web[Web app · *.azurecontainerapps.io]:::app
      Cosmos[Cosmos · public]:::data
      Storage[Storage · public]:::data
      AI[AI Foundry · public]:::data
    end

    Dev -- docker push --> ACR
    User -- HTTPS --> Web
    Web -- HTTPS --> API
    API --> Cosmos
    API --> Storage
    API --> AI
```

In this mode there is no VNet, no private endpoints, no jumpbox, and no AMPLS — useful for quick demos but not for production.
