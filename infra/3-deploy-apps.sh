#!/bin/bash

# Doc Processing Solution - Deploy Applications to Azure
# This script deploys api, web and worker applications to Azure

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
RESOURCE_GROUP=""
NAME_PREFIX="aiinvest"
ENVIRONMENT="dev"
TAG="latest"
DEPLOY_API="false"
DEPLOY_WEB="false"
DEPLOY_ALL="true"
DEBUG="false"

# Function to show usage
usage() {
    echo "Usage: $0 -g <resource-group> -r <registry> [options]"
    echo ""
    echo "Required:"
    echo "  -g, --resource-group    Azure Resource Group name"
    echo ""
    echo "Optional:"
    echo "  -p, --name-prefix      Resource name prefix (default: aiinvest)"
    echo "  -e, --environment      Environment name (default: dev)"
    echo "  -t, --tag              Image tag (default: latest)"
    echo "  --api                  Deploy API apps. If specified, only API app will be deployed."
    echo "  --web                  Deploy web app. If specified, only web app will be deployed."
    echo "  -d, --debug            Enable debug logging"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -g my-rg"
    echo "  $0 -g my-rg -e prod -t v1.0.0"
    echo "  $0 -g my-rg -e prod -t v1.0.0 --api --web"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -p|--name-prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        --api)
             DEPLOY_API="true"
             DEPLOY_ALL="false"
            shift 1
            ;;
        --web)
             DEPLOY_WEB="true"
             DEPLOY_ALL="false"
            shift 1
            ;;
        -d|--debug)
            DEBUG="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option $1"
            usage
            ;;
    esac
done

##################################
# Check deployment options

# Validate required parameters
if [ -z "$RESOURCE_GROUP" ]; then
    echo -e "${RED}❌ Error: Resource Group is required${NC}"
    usage
fi

echo -e "${BLUE}🚀 Deploying applications to Azure${NC}"
echo -e "${BLUE}Resource Group: $RESOURCE_GROUP${NC}"
echo -e "${BLUE}Name Prefix: $NAME_PREFIX${NC}"
echo -e "${BLUE}Environment: $ENVIRONMENT${NC}"
echo -e "${BLUE}Image Tag: $TAG${NC}"
echo ""

# confirm to continue
read -p "Proceed with deployment? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}⚠️ Deployment cancelled by user.${NC}"
    exit 0
fi

# Check if user is logged in to Azure
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}⚠️ You are not logged in to Azure. Please login first.${NC}"
    az login
fi

echo ""
echo -e "${YELLOW}📋 Current Azure subscription:${NC}"
az account show --output table
echo ""

    # Output what will be built
if [ "$DEPLOY_ALL" = "true" ]; then
    echo -e "${BLUE}⚙️  Deploying all apps (api, web)${NC}"
    echo ""
else
    echo -e "${BLUE}⚙️  Deploying selected apps:${NC}"
    [ "$DEPLOY_API" = "true" ] && echo -e "${BLUE}✔️ API${NC}"
    [ "$DEPLOY_WEB" = "true" ] && echo -e "${BLUE}✔️ Web${NC}"
    echo ""
fi

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
echo -e "${BLUE}📁 Moving to Project Root: $PROJECT_ROOT${NC}"
cd "$PROJECT_ROOT"

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Done with deployment options
##################################


# Function to get all deployment outputs at once
# This fetches all outputs from the infrastructure deployment and stores them in a local variable
# to avoid multiple az command calls
get_deployment_outputs() {
    local resource_group="$1"

    # Get the deployment name
    local deployment_name=$(az deployment group list \
        --resource-group "$resource_group" \
        --query "[?contains(name, 'ai-invest-appsvc')].name | [0]" \
        --output tsv)

    if [ -z "$deployment_name" ]; then
        echo -e "${RED}❌ Infrastructure deployment not found. Please run deploy-azure-infra.sh first.${NC}"
        exit 1
    fi

    # Fetch all outputs in a single call
    DEPLOYMENT_OUTPUTS=$(az deployment group show \
        --resource-group "$resource_group" \
        --name "$deployment_name" \
        --query "properties.outputs" \
        --output json)

    if [ -z "$DEPLOYMENT_OUTPUTS" ]; then
        echo -e "${RED}❌ Failed to retrieve deployment outputs.${NC}"
        exit 1
    fi
}

# Function to get a specific output property from the cached deployment outputs
get_output_property() {
    local property_name="$1"
    echo "$DEPLOYMENT_OUTPUTS" | jq -r ".${property_name}.value // empty"
}


echo ""
echo -e "${BLUE}Retrieving required parameters for deployment (${ENVIRONMENT})...${NC}"
echo "-------------------------------------------------------"

echo -e "${BLUE}Fetching deployment outputs...${NC}"
get_deployment_outputs "$RESOURCE_GROUP"
echo -e "${GREEN}✅ Deployment outputs retrieved${NC}"

echo -e "${BLUE}Retrieving parameters for deployment (${ENVIRONMENT})...${NC}"

REGISTRY=$(get_output_property "containerRegistryLoginServer")
if [ -z "$REGISTRY" ]; then
    echo -e "${RED}❌ Container Registry not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Container Registry: $REGISTRY${NC}"
fi

USER_ASSIGNED_IDENTITY_NAME=$(get_output_property "userAssignedIdentityName")
if [ -z "$USER_ASSIGNED_IDENTITY_NAME" ]; then
    echo -e "${RED}❌ User Assigned Identity Name not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ User Assigned Identity Name: $USER_ASSIGNED_IDENTITY_NAME${NC}"
fi

# Resolve UAMI client ID once (used to PATCH acrUserManagedIdentityID post-deploy
# because the bicep ARM property is not always honored on first create).
UAMI_CLIENT_ID=$(az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$USER_ASSIGNED_IDENTITY_NAME" \
    --query clientId -o tsv 2>/dev/null)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Get App Service Plan + networking info from infrastructure deployment
APP_SERVICE_PLAN_ID=$(get_output_property "appServicePlanId")
if [ -z "$APP_SERVICE_PLAN_ID" ]; then
    echo -e "${RED}❌ App Service Plan not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ App Service Plan: $APP_SERVICE_PLAN_ID${NC}"
fi

APPSVC_SUBNET_ID=$(get_output_property "appSvcSubnetId")
PE_SUBNET_ID=$(get_output_property "peSubnetId")
APPSVC_DNS_ZONE_ID=$(get_output_property "appServicePrivateDnsZoneId")
echo -e "${GREEN}✅ VNet integration subnet: $APPSVC_SUBNET_ID${NC}"
echo -e "${GREEN}✅ Private endpoint subnet: $PE_SUBNET_ID${NC}"
echo -e "${GREEN}✅ App Service private DNS zone: $APPSVC_DNS_ZONE_ID${NC}"


# Get Cosmos DB Endpoint from infrastructure deployment
COSMOS_DB_ENDPOINT=$(get_output_property "cosmosEndpoint")
if [ -z "$COSMOS_DB_ENDPOINT" ]; then
    echo -e "${RED}❌ Cosmos DB Endpoint not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Cosmos DB Endpoint: $COSMOS_DB_ENDPOINT${NC}"
fi

# Get Cosmos DB Name from infrastructure deployment
COSMOS_DB_NAME=$(get_output_property "cosmosDBName")
if [ -z "$COSMOS_DB_NAME" ]; then
    echo -e "${RED}❌ Cosmos DB Name not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Cosmos DB Name: $COSMOS_DB_NAME${NC}"
fi

# Get Storage Account Name from infrastructure deployment
STORAGE_ACCOUNT_NAME=$(get_output_property "storageAccountName")
if [ -z "$STORAGE_ACCOUNT_NAME" ]; then
    echo -e "${RED}❌ Storage Account Name not found. Please run deploy-azure-infra.sh first.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Storage Account Name: $STORAGE_ACCOUNT_NAME${NC}"
fi


echo ""
echo -e "${BLUE} Waiting for some seconds to let connections settle...${NC}"
sleep 5

echo ""
# Deploy app using Container Apps template
echo -e "${BLUE}🌐 Deploying Solution Apps...${NC}"
echo "-----------------------------------------"
optional_args=()
if [ "$DEBUG" == "true" ]; then
  optional_args+=("--debug")
fi

######################################################################
######################################################################
## API APP DEPLOYMENT

if [ "$DEPLOY_ALL" == "true" ] || [ "$DEPLOY_API" == "true" ]; then
    # Deploy API
    echo -e "${BLUE}👷 Deploying API App...${NC}"
    API_DEPLOYMENT_NAME="ai-invest-api-$(date +%s)"

    echo -e "${BLUE}Deploying API App with Bicep template...${NC}"

    # Retry logic for API deployment
    API_RETRY_COUNT=0
    API_MAX_RETRIES=3
    API_SUCCESS=false

    while [ $API_RETRY_COUNT -lt $API_MAX_RETRIES ] && [ "$API_SUCCESS" = false ]; do
        API_RETRY_COUNT=$((API_RETRY_COUNT + 1))
        echo -e "${BLUE}Attempt $API_RETRY_COUNT/$API_MAX_RETRIES: Deploying API App...${NC}"

        if az deployment group create \
            --resource-group "$RESOURCE_GROUP" \
            --template-file "api-app/infra/bicep/main.bicep" \
            --parameters \
                environment="$ENVIRONMENT" \
                namePrefix="$NAME_PREFIX" \
                appServicePlanId="$APP_SERVICE_PLAN_ID" \
                containerRegistryServer="$REGISTRY" \
                containerImage="$REGISTRY/ai-invest-api:$TAG" \
                userAssignedIdentityName="$USER_ASSIGNED_IDENTITY_NAME" \
                vnetIntegrationSubnetId="$APPSVC_SUBNET_ID" \
                privateEndpointSubnetId="$PE_SUBNET_ID" \
                appServicePrivateDnsZoneId="$APPSVC_DNS_ZONE_ID" \
                cosmosAccountEndpoint="$COSMOS_DB_ENDPOINT" \
                cosmosDbName="$COSMOS_DB_NAME" \
                storageAccountName="$STORAGE_ACCOUNT_NAME" \
            --name "$API_DEPLOYMENT_NAME" \
            --output table ${optional_args[@]}; then

            echo -e "${GREEN}✅ API App deployed successfully${NC}"

            # Get the Web App name from the deployment outputs
            API_APP_NAME=$(az deployment group show \
                --resource-group "$RESOURCE_GROUP" \
                --name "$API_DEPLOYMENT_NAME" \
                --query "properties.outputs.containerAppName.value" \
                --output tsv)

            # Get the Web App default hostname
            API_URL=$(az webapp show \
                --name "$API_APP_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --query "defaultHostName" \
                --output tsv)

            # Force a redeploy of the container image (App Service caches by digest)
            echo -e "${BLUE}Forcing the App Service to pull the latest image...${NC}"
            az webapp config container set \
                --name "${API_APP_NAME}" \
                --resource-group "$RESOURCE_GROUP" \
                --container-image-name "${REGISTRY}/ai-invest-api:${TAG}" \
                --output none
            # Workaround: ensure acrUseManagedIdentityCreds + acrUserManagedIdentityID are set
            # (bicep does not always persist these on initial create, causing 503 image-pull errors).
            if [ -n "$UAMI_CLIENT_ID" ]; then
                az rest --method PATCH \
                    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${API_APP_NAME}/config/web?api-version=2023-12-01" \
                    --body "{\"properties\":{\"acrUseManagedIdentityCreds\":true,\"acrUserManagedIdentityID\":\"${UAMI_CLIENT_ID}\"}}" \
                    --output none 2>/dev/null || true
            fi
            az webapp restart --name "${API_APP_NAME}" --resource-group "$RESOURCE_GROUP" --output none
            echo -e "${GREEN}✅ Updated Web App to pull latest image${NC}"

            if [ -n "$API_URL" ]; then
                API_URL="https://$API_URL"
                echo -e "${GREEN}API URL: $API_URL${NC}"
            else
                echo -e "${YELLOW}⚠️ Could not retrieve API URL${NC}"
            fi

            API_SUCCESS=true
        else
            echo -e "${RED}❌ API deployment failed (attempt $API_RETRY_COUNT/$API_MAX_RETRIES)${NC}"
            if [ $API_RETRY_COUNT -lt $API_MAX_RETRIES ]; then
                echo -e "${YELLOW}⚠️ Retrying API deployment in 5 seconds...${NC}"
                sleep 5
            fi
        fi
    done

    if [ "$API_SUCCESS" = false ]; then
        echo -e "${RED}❌ API deployment failed after $API_MAX_RETRIES attempts${NC}"
    fi
    echo ""
else
    echo -e "${YELLOW}⚠️ Skipping API deployment${NC}"
    echo ""
fi


######################################################################
######################################################################
## WEB APP DEPLOYMENT

if [ "$DEPLOY_ALL" == "true" ] || [ "$DEPLOY_WEB" == "true" ]; then
    # Deploy Web App (Frontend)
    echo -e "${BLUE}🌐 Deploying Web App (Frontend)...${NC}"
    WEB_DEPLOYMENT_NAME="ai-invest-web$(date +%s)"

    WEB_SUCCESS=false
    WEB_RETRY_COUNT=0
    WEB_MAX_RETRIES=3

    while [ $WEB_RETRY_COUNT -lt $WEB_MAX_RETRIES ] && [ "$WEB_SUCCESS" = false ]; do
        WEB_RETRY_COUNT=$((WEB_RETRY_COUNT + 1))
        echo -e "${BLUE}Attempt $WEB_RETRY_COUNT/$WEB_MAX_RETRIES: Deploying Web App...${NC}"

        # Deploy Web App using Bicep template
        if az deployment group create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$WEB_DEPLOYMENT_NAME" \
            --template-file "web-app/infra/bicep/main.bicep" \
            --parameters namePrefix="$NAME_PREFIX" \
                        environment="$ENVIRONMENT" \
                        containerImage="$REGISTRY/ai-invest-web:$TAG" \
                        backendApiUrl="$API_URL/api" \
                        appServicePlanId="$APP_SERVICE_PLAN_ID" \
                        containerRegistryServer="$REGISTRY" \
                        userAssignedIdentityName="$USER_ASSIGNED_IDENTITY_NAME" \
                        vnetIntegrationSubnetId="$APPSVC_SUBNET_ID" \
                        privateEndpointSubnetId="$PE_SUBNET_ID" \
                        appServicePrivateDnsZoneId="$APPSVC_DNS_ZONE_ID" \
            "${optional_args[@]}" \
            --output none; then

            echo -e "${GREEN}✅ Web App deployed successfully${NC}"

            # Get the Web App name from the deployment outputs
            WEB_APP_NAME=$(az deployment group show \
                --resource-group "$RESOURCE_GROUP" \
                --name "$WEB_DEPLOYMENT_NAME" \
                --query "properties.outputs.containerAppName.value" \
                --output tsv)

            # Get the Web App default hostname
            WEB_URL=$(az webapp show \
                --name "${WEB_APP_NAME}" \
                --resource-group "$RESOURCE_GROUP" \
                --query "defaultHostName" \
                --output tsv 2>/dev/null)

            # Force the App Service to pull the latest image
            echo -e "${BLUE}Forcing the App Service to pull the latest image...${NC}"
            az webapp config container set \
                --name "${WEB_APP_NAME}" \
                --resource-group "$RESOURCE_GROUP" \
                --container-image-name "${REGISTRY}/ai-invest-web:${TAG}" \
                --output none
            if [ -n "$UAMI_CLIENT_ID" ]; then
                az rest --method PATCH \
                    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${WEB_APP_NAME}/config/web?api-version=2023-12-01" \
                    --body "{\"properties\":{\"acrUseManagedIdentityCreds\":true,\"acrUserManagedIdentityID\":\"${UAMI_CLIENT_ID}\"}}" \
                    --output none 2>/dev/null || true
            fi
            az webapp restart --name "${WEB_APP_NAME}" --resource-group "$RESOURCE_GROUP" --output none
            echo -e "${GREEN}✅ Updated Web App to pull latest image${NC}"

            if [ -n "$WEB_URL" ]; then
                WEB_URL="https://$WEB_URL"
                echo -e "${GREEN}Web App URL: $WEB_URL${NC}"
            else
                echo -e "${YELLOW}⚠️ Could not retrieve Web App URL${NC}"
            fi

            WEB_SUCCESS=true
        else
            echo -e "${RED}❌ Web App deployment failed (attempt $WEB_RETRY_COUNT/$WEB_MAX_RETRIES)${NC}"
            if [ $WEB_RETRY_COUNT -lt $WEB_MAX_RETRIES ]; then
                echo -e "${YELLOW}⚠️ Retrying Web App deployment in 5 seconds...${NC}"
                sleep 5
            fi
        fi
    done

    if [ "$WEB_SUCCESS" = false ]; then
        echo -e "${RED}❌ Web App deployment failed after $WEB_MAX_RETRIES attempts${NC}"
    fi
    echo ""
else
    echo -e "${YELLOW}⚠️ Skipping Web App deployment${NC}"
    echo ""
fi

######################################################################
######################################################################
## LOCK DOWN AI FOUNDRY / COGNITIVE SERVICES TO VNET ONLY
## (Restrict the Foundry account so only the App Service VNet integration
## subnet can call it. The AVM Foundry module does not expose networkAcls,
## so we PATCH the account post-deploy. Idempotent.)

AI_ACCOUNT=$(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
if [ -n "$AI_ACCOUNT" ] && [ -n "$APPSVC_SUBNET_ID" ]; then
    echo -e "${BLUE}🔒 Locking AI Services account '$AI_ACCOUNT' to snet-services only...${NC}"
    az rest --method PATCH \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$AI_ACCOUNT?api-version=2024-10-01" \
        --body "{\"properties\":{\"networkAcls\":{\"defaultAction\":\"Deny\",\"bypass\":\"AzureServices\",\"virtualNetworkRules\":[{\"id\":\"$APPSVC_SUBNET_ID\",\"ignoreMissingVnetServiceEndpoint\":false}],\"ipRules\":[]}}}" \
        --output none 2>/dev/null || echo -e "${YELLOW}⚠️ Could not lock AI Services networkAcls (non-fatal).${NC}"
fi

######################################################################
######################################################################
## SUMMARY

echo ""
echo -e "${GREEN}🎉 Application deployment completed!${NC}"
echo ""
echo -e "${BLUE}📊 Deployment Summary:${NC}"
if [ "$API_SUCCESS" = true ]; then
    echo -e "${GREEN}✅ API App: $API_URL${NC}"
    echo -e "${GREEN}   Health Check: $API_URL/health${NC}"
    echo -e "${GREEN}   API Docs: $API_URL/docs${NC}"
fi
if [ "$WEB_SUCCESS" = true ]; then
    echo -e "${GREEN}✅ Web App: $WEB_URL${NC}"
fi

if [ "$API_SUCCESS" != true ] && [ "$WEB_SUCCESS" != true ] && [ "$WORKER_SUCCESS" != true ] && [ "$CRAWLER_SUCCESS" != true ]; then
    echo -e "${YELLOW}⚠️ No applications were deployed successfully.${NC}"
    echo -e "${YELLOW} - Did you run build-and-push-images.sh first?${NC}"
    echo -e "${YELLOW} - Are you missing the prefix or environment args?${NC}"
    echo -e "${YELLOW}Please check the logs above for errors.${NC}"
fi
