#!/bin/bash

# Doc Processing Solution - Build and Push Docker Images to Azure Container Registry
# This script builds Docker images and pushes them to Azure Container Registry

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
REGISTRY=""
TAG="latest"
BUILD_API="false"
BUILD_WEB="false"
BUILD_ALL="true"
# Default build mode: 'docker' builds locally and pushes (works from the
# zero-trust Windows jumpbox when Docker EE is installed and the private ACR
# is reachable via VNet). Use --acr to submit to ACR Tasks — note that against
# a private ACR this requires a VNet-enabled dedicated agent pool (Premium feature).
BUILD_MODE="docker"

# Function to show usage
usage() {
    echo "Usage: $0 -r <registry-login-server> [options]"
    echo ""
    echo "Required:"
    echo "  -r, --registry         Azure Container Registry login server"
    echo ""
    echo "Optional:"
    echo "  -t, --tag             Image tag (default: latest)"
    echo "  --api                 Build API app image. If specified, only API image will be built."
    echo "  --web                 Build web app image. If specified, only web image will be built."
    echo "  --docker              Use local Docker + docker push (legacy path; requires public ACR)"
    echo "  --acr                 Use 'az acr build' / ACR Tasks (default; works with private ACR)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -r myregistry.azurecr.io"
    echo "  $0 -r myregistry.azurecr.io -t v1.0.0"
    echo "  $0 -r myregistry.azurecr.io -t v1.0.0 --api --web"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--registry)
            REGISTRY="$2"
            shift 2
            ;;
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        --api)
             BUILD_API="true"
             BUILD_ALL="false"
            shift 1
            ;;
        --web)
             BUILD_WEB="true"
             BUILD_ALL="false"
            shift 1
            ;;
        --docker)
            BUILD_MODE="docker"
            shift 1
            ;;
        --acr)
            BUILD_MODE="acr"
            shift 1
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

# Validate required parameters
if [ -z "$REGISTRY" ]; then
    echo -e "${RED}❌ Error: Registry login server is required${NC}"
    usage
fi

echo -e "${BLUE}🚀 Building and pushing Docker images to Azure Container Registry${NC}"
echo -e "${BLUE}Registry: $REGISTRY${NC}"
echo -e "${BLUE}Tag: $TAG${NC}"
echo ""

# Output what will be built
if [ "$BUILD_ALL" = "true" ]; then
    echo -e "${BLUE}⚙️  Building all images (API, Web)${NC}"
    echo ""
else
    echo -e "${BLUE}⚙️  Building selected images:${NC}"
    [ "$BUILD_API" = "true" ] && echo -e "${BLUE}✔️ API${NC}"
    [ "$BUILD_WEB" = "true" ] && echo -e "${BLUE}✔️ Web${NC}"
    echo ""
fi

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}📁 Moving to Project Root: $PROJECT_ROOT${NC}"
# Change to project root
cd "$PROJECT_ROOT"

# Check if Docker is running (only required in docker mode)
if [ "$BUILD_MODE" == "docker" ]; then
    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}❌ Docker is not running. Please start Docker first (or use default --acr mode).${NC}"
        exit 1
    fi
fi

#Check if npm is installed
if ! command -v npm &> /dev/null; then
    echo -e "${RED}❌ npm is not installed. Please install Node.js and npm first.${NC}"
    exit 1
fi

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if user is logged in to Azure
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}⚠️ You are not logged in to Azure. Please login first.${NC}"
    az login
fi

echo ""
echo -e "${YELLOW}📋 Current Azure subscription:${NC}"
az account show --output table

# Login to Azure Container Registry (docker path only)
if [ "$BUILD_MODE" == "docker" ]; then
    echo ""
    echo -e "${BLUE}🔐 Logging in to Azure Container Registry...${NC}"
    az acr login --name "${REGISTRY%%.*}"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to login to Azure Container Registry${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Successfully logged in to ACR${NC}"
    echo ""
fi

# Get Resource Group of the ACR
RESOURCE_GROUP=$(az acr show --name "${REGISTRY%%.*}" --query "resourceGroup" -o tsv)


# Function to build and push image
build_and_push() {
    local name=$1
    local dockerfile=$2
    local context=$3
    local image_ref="ai-invest-$name:$TAG"
    local full_image_name="$REGISTRY/$image_ref"

    echo -e "${YELLOW}📦 Building $name (mode=$BUILD_MODE)...${NC}"
    echo -e "${YELLOW}📁  Using docker file: $dockerfile${NC}"
    echo -e "${YELLOW}📁  Context: $context${NC}"
    echo -e "${YELLOW}🏷️  Tagging image as $full_image_name${NC}"

    if [ "$BUILD_MODE" == "acr" ]; then
        if az acr build \
            --registry "${REGISTRY%%.*}" \
            --image "$image_ref" \
            --platform linux/amd64 \
            --file "$dockerfile" \
            "$context"; then
            echo -e "${GREEN}✅ Successfully built and pushed $full_image_name via ACR Tasks${NC}"
        else
            echo -e "${RED}❌ Failed to build/push $name via ACR Tasks${NC}"
            return 1
        fi
    else
        if docker buildx build --platform linux/amd64 -t "$full_image_name" -f "$dockerfile" "$context"; then
            echo -e "${GREEN}✅ Successfully built $full_image_name${NC}"

            echo -e "${YELLOW}📤 Pushing $name to registry...${NC}"
            if docker push "$full_image_name"; then
                echo -e "${GREEN}✅ Successfully pushed $full_image_name${NC}"
            else
                echo -e "${RED}❌ Failed to push $name${NC}"
                return 1
            fi
        else
            echo -e "${RED}❌ Failed to build $name${NC}"
            return 1
        fi
    fi
    printf -- '-%.0s' {1..100}
    echo ""
    echo ""
}


# Build and push all images
printf '=%.0s' {1..100}
echo ""
echo ""
echo -e "${BLUE}Building and pushing images...${NC}"
echo ""

# Build API
if [ "$BUILD_ALL" = "true" ] || [ "$BUILD_API" = "true" ]; then
    build_and_push "api" "api-app/Dockerfile" "."
    echo "#" * 50
fi

# Build Web
if [ "$BUILD_ALL" = "true" ] || [ "$BUILD_WEB" = "true" ]; then
    # build npm dependencies first
    echo -e "${YELLOW}📦 Installing npm dependencies for web app...${NC}"
    cd web-app
    if npm install; then
        echo -e "${GREEN}✅ Successfully installed npm dependencies${NC}"
    else
        echo -e "${RED}❌ Failed to install npm dependencies${NC}"
        exit 1
    fi
    cd ..
    build_and_push "web" "web-app/Dockerfile" "."
fi


echo -e "${GREEN}🎉 Image(s) built and pushed successfully!${NC}"
echo ""
echo ""
echo -e "${BLUE}📊 Pushed Image(s):${NC}"
if [ "$BUILD_ALL" = "true" ] || [ "$BUILD_API" = "true" ]; then
    echo -e "${GREEN}✅ $REGISTRY/ai-invest-api:$TAG${NC}"
fi
if [ "$BUILD_ALL" = "true" ] || [ "$BUILD_WEB" = "true" ]; then
    echo -e "${GREEN}✅ $REGISTRY/ai-invest-web:$TAG${NC}"
fi

echo ""
echo ""
echo -e "${BLUE}➡️ Next step: Deploy the applications using the deployment script${NC}"
echo "   ./infra/3-deploy-apps.sh -g $RESOURCE_GROUP"
echo ""