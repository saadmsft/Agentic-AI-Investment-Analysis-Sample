#!/bin/bash
# Connect to the zero-trust jumpbox VM over Azure Bastion using SSH tunneling.
#
# Prerequisites on your laptop:
#   - Azure CLI + ssh
#   - Logged in with 'az login' to the same subscription
#   - Bastion SKU must be 'Standard' (tunneling is not supported on Basic)
#
# Usage: ./infra/0-connect-jumpbox.sh -g <resource-group> [options]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESOURCE_GROUP=""
ADMIN_USER="azureuser"
PORT="50022"

usage() {
    echo "Usage: $0 -g <resource-group> [options]"
    echo "  -g, --resource-group   Azure Resource Group name (required)"
    echo "  -u, --user             SSH user on the jumpbox (default: azureuser)"
    echo "  -p, --local-port       Local port for the Bastion tunnel (default: 50022)"
    echo "  -h, --help             Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        -u|--user)           ADMIN_USER="$2"; shift 2 ;;
        -p|--local-port)     PORT="$2"; shift 2 ;;
        -h|--help)           usage ;;
        *) echo "Unknown option $1"; usage ;;
    esac
done

[ -z "$RESOURCE_GROUP" ] && usage

# Find jumpbox + bastion from the infra deployment outputs
DEPLOYMENT_NAME=$(az deployment group list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?contains(name, 'ai-invest-sample')] | sort_by(@, &properties.timestamp) | [-1].name" \
    --output tsv)

if [ -z "$DEPLOYMENT_NAME" ]; then
    echo -e "${RED}❌ Infrastructure deployment not found in $RESOURCE_GROUP.${NC}"
    exit 1
fi

JUMPBOX_NAME=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.jumpboxName.value" -o tsv)
BASTION_NAME=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.bastionName.value" -o tsv)

if [ -z "$JUMPBOX_NAME" ] || [ -z "$BASTION_NAME" ]; then
    echo -e "${RED}❌ No jumpbox/bastion found in deployment outputs. Was the infra deployed with isPrivate=true and deployJumpbox=true?${NC}"
    exit 1
fi

JUMPBOX_ID=$(az vm show -g "$RESOURCE_GROUP" -n "$JUMPBOX_NAME" --query id -o tsv)

echo -e "${BLUE}🔐 Opening SSH session to jumpbox via Bastion...${NC}"
echo -e "${BLUE}  Jumpbox: $JUMPBOX_NAME${NC}"
echo -e "${BLUE}  Bastion: $BASTION_NAME${NC}"
echo ""
echo -e "${YELLOW}Once connected, clone the repo and run scripts 2 and 3 from the jumpbox:${NC}"
echo -e "${YELLOW}  git clone <this-repo-url>${NC}"
echo -e "${YELLOW}  cd Agentic-AI-Investment-Analysis-Sample${NC}"
echo -e "${YELLOW}  ./infra/2-build-and-push-images.sh -r <acrLoginServer>${NC}"
echo -e "${YELLOW}  ./infra/3-deploy-apps.sh -g $RESOURCE_GROUP${NC}"
echo ""

az network bastion ssh \
    --name "$BASTION_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --target-resource-id "$JUMPBOX_ID" \
    --auth-type ssh-key \
    --username "$ADMIN_USER" \
    --ssh-key "$HOME/.ssh/id_rsa"
