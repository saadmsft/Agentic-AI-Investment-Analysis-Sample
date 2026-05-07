#!/bin/bash
# Connect to the zero-trust Windows jumpbox VM over Azure Bastion using RDP.
#
# Prerequisites on your laptop:
#   - Azure CLI (logged in with `az login` to the same subscription)
#   - Bastion SKU must be 'Standard' (native-client tunneling not supported on Basic)
#   - On macOS/Linux: an RDP client (e.g. Microsoft Remote Desktop on macOS,
#     `xfreerdp` / `remmina` on Linux). The script opens an `az network bastion
#     tunnel` to the VM's RDP port and you connect your client to localhost.
#   - On Windows: nothing extra — `az network bastion rdp` launches mstsc directly.
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
PORT="50389"
MODE="auto"   # auto | tunnel | rdp

usage() {
    echo "Usage: $0 -g <resource-group> [options]"
    echo "  -g, --resource-group   Azure Resource Group name (required)"
    echo "  -u, --user             RDP user on the jumpbox (default: azureuser)"
    echo "  -p, --local-port       Local port for the Bastion tunnel (default: 50389)"
    echo "      --tunnel           Force tunnel mode (open localhost:<port> -> VM:3389)"
    echo "      --rdp              Force native 'az network bastion rdp' mode (Windows only)"
    echo "  -h, --help             Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        -u|--user)           ADMIN_USER="$2"; shift 2 ;;
        -p|--local-port)     PORT="$2"; shift 2 ;;
        --tunnel)            MODE="tunnel"; shift ;;
        --rdp)               MODE="rdp"; shift ;;
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

# Auto-pick the right command per host OS.
if [ "$MODE" == "auto" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) MODE="rdp" ;;
        *)                    MODE="tunnel" ;;
    esac
fi

echo -e "${BLUE}🔐 Opening RDP session to Windows jumpbox via Bastion...${NC}"
echo -e "${BLUE}  Jumpbox: $JUMPBOX_NAME${NC}"
echo -e "${BLUE}  Bastion: $BASTION_NAME${NC}"
echo -e "${BLUE}  Mode:    $MODE${NC}"
echo ""

if [ "$MODE" == "rdp" ]; then
    echo -e "${YELLOW}Launching native RDP client (Windows mstsc)...${NC}"
    az network bastion rdp \
        --name "$BASTION_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --target-resource-id "$JUMPBOX_ID"
else
    echo -e "${YELLOW}Opening Bastion tunnel on localhost:$PORT -> $JUMPBOX_NAME:3389${NC}"
    echo -e "${YELLOW}Connect your RDP client to:  localhost:$PORT${NC}"
    echo -e "${YELLOW}  User:     $ADMIN_USER${NC}"
    echo -e "${YELLOW}  Password: (the admin password you set during deployment)${NC}"
    echo ""
    echo -e "${YELLOW}On macOS:  open 'Microsoft Remote Desktop' and add a PC at localhost:$PORT${NC}"
    echo -e "${YELLOW}On Linux:  xfreerdp /v:localhost:$PORT /u:$ADMIN_USER${NC}"
    echo ""
    echo -e "${YELLOW}Once connected, on the jumpbox open PowerShell and run:${NC}"
    echo -e "${YELLOW}  cd C:\\Users\\Public\\Desktop\\Agentic-AI-Investment-Analysis-Sample${NC}"
    echo -e "${YELLOW}  bash infra/2-build-and-push-images.sh -r <acrLoginServer>${NC}"
    echo -e "${YELLOW}  bash infra/3-deploy-apps.sh           -g $RESOURCE_GROUP${NC}"
    echo ""
    echo -e "${BLUE}Press Ctrl+C in this terminal to close the tunnel when finished.${NC}"
    az network bastion tunnel \
        --name "$BASTION_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --target-resource-id "$JUMPBOX_ID" \
        --resource-port 3389 \
        --port "$PORT"
fi
