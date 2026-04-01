#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${CYAN}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_header() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}========================================${NC}"; }

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_header "Advanced WebApp Kubernetes Deployment"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
print_info "Working directory: $SCRIPT_DIR"

# ============================================
# Prerequisites Check
# ============================================
print_info "\n[1/13] Checking prerequisites..."

if ! command_exists kubectl; then
    print_error "kubectl is not installed"
    exit 1
fi
print_success "kubectl found"

if ! command_exists docker; then
    print_error "docker is not installed"
    exit 1
fi
print_success "docker found"

if ! kubectl cluster-info &>/dev/null; then
    print_error "Kubernetes cluster is not running"
    print_warning "Please start Docker Desktop Kubernetes"
    exit 1
fi
print_success "Kubernetes cluster is running"

# Detect Kubernetes environment
K8S_CONTEXT=$(kubectl config current-context)
print_info "Current context: $K8S_CONTEXT"

if [[ "$K8S_CONTEXT" == *"kind"* ]]; then
    K8S_ENV="kind"
    print_info "Detected: Kind cluster"
elif [[ "$K8S_CONTEXT" == *"docker-desktop"* ]]; then
    K8S_ENV="docker-desktop"
    print_info "Detected: Docker Desktop"
elif [[ "$K8S_CONTEXT" == *"minikube"* ]]; then
    K8S_ENV="minikube"
    print_info "Detected: Minikube"
else
    K8S_ENV="unknown"
    print_warning "Unknown Kubernetes environment: $K8S_CONTEXT"
fi

# ============================================
# Check Ingress Controller
# ============================================
print_info "\n[2/13] Checking Ingress Controller..."
if ! kubectl get namespace ingress-nginx &> /dev/null; then
    print_warning "NGINX Ingress Controller not found. Installing..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
    
    print_info "Waiting for Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=120s
    print_success "Ingress Controller installed"
else
    print_success "Ingress Controller already installed"
fi

# ============================================
# Cleanup Previous Deployment
# ============================================
print_info "\n[3/13] Cleaning up previous deployment..."

if kubectl get namespace webapp &>/dev/null; then
    print_warning "Removing existing webapp namespace..."
    kubectl delete namespace webapp --ignore-not-found=true --timeout=60s
    
    # Wait for namespace to be fully deleted
    print_info "Waiting for cleanup to complete..."
    while kubectl get namespace webapp &>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo ""
    print_success "Previous deployment cleaned up"
else
    print_success "No previous deployment found"
fi

# Give system time to fully clean up
sleep 3

# ============================================
# Check for WebApp Docker Image
# ============================================
print_info "\n[4/13] Checking for WebApp Docker image..."

WEBAPP_IMAGE_EXISTS=$(docker images webapp --format "{{.Repository}}:{{.Tag}}" | grep "webapp:latest" || true)

if [ -n "$WEBAPP_IMAGE_EXISTS" ]; then
    print_success "Found existing webapp:latest image"
    
    # Ask if user wants to rebuild
    read -p "Rebuild the image? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Removing old webapp image..."
        docker rmi webapp:latest 2>/dev/null || true
        BUILD_IMAGE=true
    else
        BUILD_IMAGE=false
        print_info "Using existing image"
    fi
else
    print_warning "webapp:latest image not found"
    BUILD_IMAGE=true
fi

# ============================================
# Pull MongoDB Image
# ============================================
print_info "\n[5/13] Checking MongoDB image..."

if docker images mongo:7.0 --format "{{.Repository}}:{{.Tag}}" | grep -q "mongo:7.0"; then
    print_success "MongoDB 7.0 image already exists"
else
    print_info "Pulling MongoDB image..."
    if docker pull mongo:7.0; then
        print_success "MongoDB image pulled successfully"
    else
        print_error "Failed to pull MongoDB image"
        exit 1
    fi
fi

# ============================================
# Build WebApp Image (if needed)
# ============================================
if [ "$BUILD_IMAGE" = true ]; then
    print_info "\n[6/13] Building WebApp Docker image..."

    # Navigate to webapp directory
    WEBAPP_DIR="$SCRIPT_DIR/webapp-k8s/webapp"
    
    # Try alternate location
    if [ ! -d "$WEBAPP_DIR" ]; then
        WEBAPP_DIR="$SCRIPT_DIR/webapp"
    fi
    
    if [ ! -d "$WEBAPP_DIR" ]; then
        print_error "webapp directory not found!"
        print_info "Searched in:"
        print_info "  - $SCRIPT_DIR/webapp-k8s/webapp"
        print_info "  - $SCRIPT_DIR/webapp"
        exit 1
    fi

    print_info "Using webapp directory: $WEBAPP_DIR"
    cd "$WEBAPP_DIR"

    # Verify required files exist
    print_info "Verifying files..."
    MISSING_FILES=false
    for file in server.js package.json Dockerfile; do
        if [ ! -f "$file" ]; then
            print_error "Required file missing: $file"
            MISSING_FILES=true
        fi
    done
    
    if [ "$MISSING_FILES" = true ]; then
        exit 1
    fi
    
    print_success "All required files present"

    # Build with no cache for fresh build
    print_info "Building Docker image (this may take a few minutes)..."
    if docker build --no-cache -t webapp:latest . 2>&1 | tee /tmp/docker-build.log; then
        print_success "Docker image built successfully"
    else
        print_error "Docker build failed. Check /tmp/docker-build.log for details"
        exit 1
    fi

    cd "$SCRIPT_DIR"
else
    print_info "\n[6/13] Skipping image build (using existing image)"
fi

# ============================================
# Load Image into Kubernetes Nodes
# ============================================
print_info "\n[7/13] Loading image into Kubernetes nodes..."

if [ "$K8S_ENV" = "kind" ]; then
    print_info "Loading image into Kind cluster..."
    CLUSTER_NAME=$(kubectl config current-context | sed 's/kind-//')
    if kind load docker-image webapp:latest --name "$CLUSTER_NAME" 2>/dev/null; then
        print_success "Image loaded into Kind nodes"
    else
        print_warning "Failed to load image into Kind (may not be needed)"
    fi
elif [ "$K8S_ENV" = "minikube" ]; then
    print_info "Loading image into Minikube..."
    if minikube image load webapp:latest 2>/dev/null; then
        print_success "Image loaded into Minikube"
    else
        print_warning "Failed to load image into Minikube (may not be needed)"
    fi
elif [ "$K8S_ENV" = "docker-desktop" ]; then
    print_success "Docker Desktop - images available automatically"
else
    print_info "Unknown environment - assuming images are available"
fi

# ============================================
# Verify Docker Image
# ============================================
print_info "\n[8/13] Verifying Docker image..."

# Check if image exists
if ! docker images webapp:latest --format "{{.Repository}}:{{.Tag}}" | grep -q "webapp:latest"; then
    print_error "Docker image webapp:latest not found!"
    print_info "Available images:"
    docker images | grep webapp || true
    exit 1
fi
print_success "Docker image verified"

# Display images
print_info "\nDocker images:"
docker images | grep -E "REPOSITORY|mongo:7.0|webapp:latest"

# ============================================
# Update Deployment for Environment
# ============================================
print_info "\n[9/13] Preparing deployment configuration..."

K8S_DIR="$SCRIPT_DIR/webapp-k8s/k8s"
if [ ! -d "$K8S_DIR" ]; then
    K8S_DIR="$SCRIPT_DIR/k8s"
fi

if [ ! -d "$K8S_DIR" ]; then
    print_error "Kubernetes manifests directory not found!"
    exit 1
fi

# Backup original deployment
cp "$K8S_DIR/webapp-deployment.yaml" "$K8S_DIR/webapp-deployment.yaml.bak" 2>/dev/null || true

# Set appropriate imagePullPolicy based on environment
if [ "$K8S_ENV" = "kind" ] || [ "$K8S_ENV" = "minikube" ]; then
    IMAGE_PULL_POLICY="IfNotPresent"
else
    IMAGE_PULL_POLICY="IfNotPresent"  # Changed from Never to IfNotPresent
fi

print_info "Using imagePullPolicy: $IMAGE_PULL_POLICY"

# Update deployment file
sed -i.tmp "s/imagePullPolicy: .*/imagePullPolicy: $IMAGE_PULL_POLICY/" "$K8S_DIR/webapp-deployment.yaml"
rm -f "$K8S_DIR/webapp-deployment.yaml.tmp"

print_success "Deployment configuration ready"

# ============================================
# Create Namespace
# ============================================
print_info "\n[10/13] Creating namespace..."
kubectl apply -f "$K8S_DIR/namespace.yaml"
sleep 2
print_success "Namespace created"

# ============================================
# Deploy MongoDB
# ============================================
print_info "\n[11/13] Deploying MongoDB..."

kubectl apply -f "$K8S_DIR/mongodb-secret.yaml"
kubectl apply -f "$K8S_DIR/mongodb-configmap.yaml"
kubectl apply -f "$K8S_DIR/mongodb-pvc.yaml"
kubectl apply -f "$K8S_DIR/mongodb-deployment.yaml"
kubectl apply -f "$K8S_DIR/mongodb-service.yaml"

print_success "MongoDB resources created"

# Wait for MongoDB
print_info "\nWaiting for MongoDB to be ready (max 2 minutes)..."
if kubectl wait --for=condition=ready pod -l app=mongodb -n webapp --timeout=120s 2>/dev/null; then
    print_success "MongoDB is ready!"
else
    print_warning "MongoDB readiness timeout, checking status..."
    kubectl get pods -n webapp -l app=mongodb
    
    # Check if pod is running
    POD_STATUS=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$POD_STATUS" = "Running" ]; then
        print_success "MongoDB pod is running"
        sleep 10
    else
        print_error "MongoDB deployment failed"
        kubectl logs -l app=mongodb -n webapp --tail=50 2>/dev/null || true
        exit 1
    fi
fi

# ============================================
# Deploy WebApp
# ============================================
print_info "\n[12/13] Deploying WebApp..."

kubectl apply -f "$K8S_DIR/webapp-deployment.yaml"
kubectl apply -f "$K8S_DIR/webapp-service.yaml"

print_success "WebApp resources created"

# Wait for WebApp with better error handling
print_info "\nWaiting for WebApp to be ready (max 3 minutes)..."

WAIT_TIME=0
MAX_WAIT=180
READY=false

while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    RUNNING_PODS=$(kubectl get pods -n webapp -l app=webapp --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    TOTAL_PODS=$(kubectl get pods -n webapp -l app=webapp --no-headers 2>/dev/null | wc -l)
    
    # Check for image pull errors
    IMAGE_ERRORS=$(kubectl get pods -n webapp -l app=webapp -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "Image" || true)
    
    if [ -n "$IMAGE_ERRORS" ]; then
        print_error "Image pull error detected: $IMAGE_ERRORS"
        print_info "\nPod details:"
        kubectl describe pods -n webapp -l app=webapp | grep -A 10 "Events:"
        
        print_error "\nImage is not accessible to Kubernetes nodes!"
        print_info "Try one of these solutions:"
        print_info "1. For Kind: kind load docker-image webapp:latest --name <cluster-name>"
        print_info "2. For Minikube: minikube image load webapp:latest"
        print_info "3. Push to a registry and update deployment"
        exit 1
    fi
    
    if [ "$RUNNING_PODS" -gt 0 ]; then
        print_success "WebApp pods are running ($RUNNING_PODS/$TOTAL_PODS)"
        READY=true
        break
    fi
    
    # Show status every 10 seconds
    if [ $((WAIT_TIME % 10)) -eq 0 ]; then
        echo "  Waiting... ($WAIT_TIME/$MAX_WAIT seconds)"
        kubectl get pods -n webapp -l app=webapp --no-headers
    fi
    
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
done

if [ "$READY" = false ]; then
    print_error "WebApp failed to start"
    print_info "\nPod Status:"
    kubectl get pods -n webapp -l app=webapp
    
    print_info "\nPod Description:"
    kubectl describe pod -l app=webapp -n webapp | tail -100
    
    print_info "\nPod Logs:"
    kubectl logs -l app=webapp -n webapp --tail=50 --all-containers=true 2>/dev/null || true
    
    print_error "Deployment failed. Please check the errors above."
    exit 1
fi

# Additional wait for readiness probes
print_info "Waiting for readiness probes to pass..."
sleep 15

# ============================================
# Deploy Ingress
# ============================================
print_info "\n[13/13] Deploying Ingress..."

if kubectl get ingressclass nginx &>/dev/null; then
    kubectl apply -f "$K8S_DIR/webapp-ingress.yaml"
    print_success "Ingress created"
    INGRESS_DEPLOYED=true
else
    print_warning "NGINX Ingress class not found. Skipping ingress deployment."
    INGRESS_DEPLOYED=false
fi

sleep 3

# ============================================
# Verify Deployment
# ============================================
print_info "\n[14/13] Verifying deployment..."

# Check webapp pods
RUNNING_PODS=$(kubectl get pods -n webapp -l app=webapp --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$RUNNING_PODS" -gt 0 ]; then
    print_success "$RUNNING_PODS WebApp pod(s) running"
    
    # Test health endpoint from within pod
    POD_NAME=$(kubectl get pods -n webapp -l app=webapp -o jsonpath='{.items[0].metadata.name}')
    print_info "Testing health endpoint in pod: $POD_NAME"
    
    sleep 5
    if kubectl exec $POD_NAME -n webapp -- wget -qO- http://localhost:3000/health &>/dev/null; then
        print_success "Health endpoint responding"
    else
        print_warning "Health endpoint not responding yet (may need more time)"
        print_info "Checking pod logs..."
        kubectl logs $POD_NAME -n webapp --tail=20
    fi
    
else
    print_error "No running WebApp pods found!"
    exit 1
fi

# Test external connectivity
SERVICE_TYPE=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.type}')
if [ "$SERVICE_TYPE" = "NodePort" ]; then
    NODE_PORT=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.ports[0].nodePort}')
    
    print_info "Testing external connectivity on port $NODE_PORT..."
    sleep 5
    
    if curl -s -f "http://localhost:$NODE_PORT/health" &>/dev/null; then
        print_success "External access working!"
    else
        print_warning "External access not ready yet (service may need more time)"
    fi
fi

# Restore backup
if [ -f "$K8S_DIR/webapp-deployment.yaml.bak" ]; then
    mv "$K8S_DIR/webapp-deployment.yaml.bak" "$K8S_DIR/webapp-deployment.yaml"
fi

# ============================================
# Display Deployment Status
# ============================================
print_header "Deployment Complete!"

echo -e "\n${CYAN}Pod Status:${NC}"
kubectl get pods -n webapp -o wide

echo -e "\n${CYAN}Service Status:${NC}"
kubectl get services -n webapp

if [ "$INGRESS_DEPLOYED" = true ]; then
    echo -e "\n${CYAN}Ingress Status:${NC}"
    kubectl get ingress -n webapp
fi

# ============================================
# Access Information
# ============================================
print_header "Access Information"

SERVICE_TYPE=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.type}')

if [ "$SERVICE_TYPE" = "NodePort" ]; then
    NODE_PORT=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.ports[0].nodePort}')
    print_success "WebApp URL: http://localhost:$NODE_PORT"
    echo ""
    echo -e "${GREEN}Available Pages:${NC}"
    echo "  • Home:      http://localhost:$NODE_PORT/"
    echo "  • Register:  http://localhost:$NODE_PORT/register"
    echo "  • Login:     http://localhost:$NODE_PORT/login"
    echo "  • Dashboard: http://localhost:$NODE_PORT/dashboard (Advanced Chat)"
    echo "  • Users:     http://localhost:$NODE_PORT/users"
    echo "  • Health:    http://localhost:$NODE_PORT/health"
    
    ACCESS_URL="http://localhost:$NODE_PORT"
else
    ACCESS_URL="http://localhost"
fi

# ============================================
# Advanced Chat Features
# ============================================
print_header "Advanced Chat Features"

echo -e "${GREEN}✓ Real-time Messaging${NC} - Instant message delivery"
echo -e "${GREEN}✓ Multiple Chat Rooms${NC} - General, Tech, Fun + Create your own"
echo -e "${GREEN}✓ Message Reactions${NC} - React with 👍❤️😂"
echo -e "${GREEN}✓ File/Image Sharing${NC} - Upload and share media"
echo -e "${GREEN}✓ Voice Messages${NC} - Record audio messages"
echo -e "${GREEN}✓ Edit/Delete Messages${NC} - Modify your messages"
echo -e "${GREEN}✓ User Status${NC} - Online/Away/Busy"
echo -e "${GREEN}✓ Typing Indicators${NC} - See when others type"
echo -e "${GREEN}✓ Message Search${NC} - Search chat history"
echo -e "${GREEN}✓ Emoji Picker${NC} - Built-in emoji support"

print_header "Quick Start"

echo "1. Open: ${ACCESS_URL}"
echo "2. Register a new account"
echo "3. Login and start chatting!"
echo ""
echo "For testing, open another browser (incognito) for a second user"

print_header "Deployment Successful! 🎉"
echo ""
echo -e "${YELLOW}Open ${ACCESS_URL} in your browser${NC}"
echo ""
