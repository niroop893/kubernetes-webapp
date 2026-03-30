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

print_header "WebApp Kubernetes Deployment"

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

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
print_info "Script directory: $SCRIPT_DIR"

# ============================================
# Verify Files Exist
# ============================================
print_info "\n[2/13] Verifying webapp files..."

if [ ! -f "$SCRIPT_DIR/webapp/public/dashboard.html" ]; then
    print_error "dashboard.html not found!"
    exit 1
fi
print_success "dashboard.html found"

if [ ! -f "$SCRIPT_DIR/webapp/public/users.html" ]; then
    print_error "users.html not found!"
    exit 1
fi
print_success "users.html found"

if [ ! -f "$SCRIPT_DIR/webapp/server.js" ]; then
    print_error "server.js not found!"
    exit 1
fi
print_success "server.js found"

# Verify routes exist in server.js
if grep -q "'/dashboard'" "$SCRIPT_DIR/webapp/server.js" && grep -q "'/users'" "$SCRIPT_DIR/webapp/server.js"; then
    print_success "Dashboard and Users routes found in server.js"
else
    print_error "Dashboard or Users routes not found in server.js"
    exit 1
fi

# ============================================
# Cleanup Previous Deployment
# ============================================
print_info "\n[3/13] Cleaning up previous deployment..."

# Check if namespace exists
if kubectl get namespace webapp &>/dev/null; then
    print_warning "Found existing webapp namespace. Cleaning up..."

    # Delete resources individually for faster cleanup
    kubectl delete ingress --all -n webapp --ignore-not-found=true --timeout=30s &
    kubectl delete service --all -n webapp --ignore-not-found=true --timeout=30s &
    kubectl delete deployment --all -n webapp --ignore-not-found=true --timeout=30s &
    kubectl delete pvc --all -n webapp --ignore-not-found=true --timeout=30s &
    kubectl delete configmap --all -n webapp --ignore-not-found=true --timeout=30s &
    kubectl delete secret --all -n webapp --ignore-not-found=true --timeout=30s &

    # Wait for all background jobs
    wait

    # Delete namespace
    kubectl delete namespace webapp --ignore-not-found=true --timeout=60s
    print_success "Previous deployment cleaned up"
else
    print_success "No previous deployment found"
fi

# Wait for namespace to be fully deleted
print_info "Waiting for cleanup to complete..."
while kubectl get namespace webapp &>/dev/null; do
    echo -n "."
    sleep 2
done
echo ""
print_success "Cleanup completed"

# ============================================
# Clean Old Docker Images
# ============================================
print_info "\n[4/13] Cleaning old Docker images..."
docker rmi webapp:latest webapp:v2 2>/dev/null || true
print_success "Old images removed"

# ============================================
# Pull MongoDB Image
# ============================================
print_info "\n[5/13] Pulling MongoDB image..."
if docker pull mongo:7.0; then
    print_success "MongoDB image pulled successfully"
else
    print_error "Failed to pull MongoDB image"
    exit 1
fi

# ============================================
# Build WebApp Image (No Cache)
# ============================================
print_info "\n[6/13] Building WebApp Docker image (fresh build)..."
cd "$SCRIPT_DIR/webapp"

# Build with no cache and timestamp tag
BUILD_TAG="v2-$(date +%s)"
print_info "Building with tag: $BUILD_TAG"

if docker build --no-cache -t webapp:$BUILD_TAG -t webapp:latest .; then
    print_success "WebApp image built successfully with tag: $BUILD_TAG"
else
    print_error "Docker build failed"
    exit 1
fi

cd "$SCRIPT_DIR"

# ============================================
# Verify Files in Docker Image
# ============================================
print_info "\n[7/13] Verifying files in Docker image..."

# Create temporary container to check files
TEMP_CONTAINER=$(docker create webapp:latest)

# Check if files exist in container
docker cp $TEMP_CONTAINER:/app/public/dashboard.html /tmp/test-dashboard.html &>/dev/null
if [ -f /tmp/test-dashboard.html ]; then
    print_success "dashboard.html exists in image"
    rm /tmp/test-dashboard.html
else
    print_error "dashboard.html NOT found in image!"
    docker rm $TEMP_CONTAINER
    exit 1
fi

docker cp $TEMP_CONTAINER:/app/public/users.html /tmp/test-users.html &>/dev/null
if [ -f /tmp/test-users.html ]; then
    print_success "users.html exists in image"
    rm /tmp/test-users.html
else
    print_error "users.html NOT found in image!"
    docker rm $TEMP_CONTAINER
    exit 1
fi

# Clean up temp container
docker rm $TEMP_CONTAINER &>/dev/null
print_success "All required files verified in Docker image"

# ============================================
# Verify Images
# ============================================
print_info "\n[8/13] Docker images:"
docker images | grep -E "REPOSITORY|mongo:7.0|webapp"

# ============================================
# Update Deployment YAML with New Tag
# ============================================
print_info "\n[9/13] Updating deployment to use new image..."

# Backup original
cp "$SCRIPT_DIR/k8s/webapp-deployment.yaml" "$SCRIPT_DIR/k8s/webapp-deployment.yaml.bak"

# Update image tag in deployment (for both latest and specific version scenarios)
sed -i.tmp "s|image: webapp:.*|image: webapp:$BUILD_TAG|g" "$SCRIPT_DIR/k8s/webapp-deployment.yaml"
rm -f "$SCRIPT_DIR/k8s/webapp-deployment.yaml.tmp"

print_success "Deployment updated to use image: webapp:$BUILD_TAG"

# ============================================
# Create Namespace
# ============================================
print_info "\n[10/13] Creating namespace..."
kubectl apply -f "$SCRIPT_DIR/k8s/namespace.yaml"
print_success "Namespace created"

# ============================================
# Deploy MongoDB
# ============================================
print_info "\n[11/13] Deploying MongoDB..."
kubectl apply -f "$SCRIPT_DIR/k8s/mongodb-secret.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/mongodb-configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/mongodb-pvc.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/mongodb-deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/mongodb-service.yaml"
print_success "MongoDB resources created"

# Wait for MongoDB
print_info "\nWaiting for MongoDB to be ready (max 2 minutes)..."
if kubectl wait --for=condition=ready pod -l app=mongodb -n webapp --timeout=120s; then
    print_success "MongoDB is ready!"
else
    print_error "MongoDB failed to become ready"
    kubectl get pods -n webapp -l app=mongodb
    kubectl logs -l app=mongodb -n webapp --tail=50
    exit 1
fi

# ============================================
# Deploy WebApp
# ============================================
print_info "\n[12/13] Deploying WebApp..."
kubectl apply -f "$SCRIPT_DIR/k8s/webapp-deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/webapp-service.yaml"
print_success "WebApp resources created"

# Deploy Ingress if controller exists
if kubectl get ingressclass nginx &>/dev/null; then
    kubectl apply -f "$SCRIPT_DIR/k8s/webapp-ingress.yaml"
    print_success "WebApp ingress created"
    INGRESS_DEPLOYED=true
else
    print_warning "NGINX Ingress Controller not found. Skipping ingress."
    INGRESS_DEPLOYED=false
fi

# Wait for WebApp
print_info "\nWaiting for WebApp to be ready (max 3 minutes)..."
if kubectl wait --for=condition=ready pod -l app=webapp -n webapp --timeout=180s; then
    print_success "WebApp is ready!"
else
    print_warning "WebApp readiness timeout, checking status..."
    kubectl get pods -n webapp -l app=webapp
fi

# ============================================
# Verify Deployment
# ============================================
print_info "\n[13/13] Verifying deployment..."

# Check if pods are running
RUNNING_PODS=$(kubectl get pods -n webapp -l app=webapp --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$RUNNING_PODS" -gt 0 ]; then
    print_success "$RUNNING_PODS WebApp pod(s) running"

    # Verify files exist in running pod
    POD_NAME=$(kubectl get pods -n webapp -l app=webapp -o jsonpath='{.items[0].metadata.name}')
    print_info "Verifying files in pod: $POD_NAME"

    if kubectl exec $POD_NAME -n webapp -- ls /app/public/dashboard.html &>/dev/null; then
        print_success "dashboard.html exists in running pod"
    else
        print_error "dashboard.html NOT found in running pod!"
    fi

    if kubectl exec $POD_NAME -n webapp -- ls /app/public/users.html &>/dev/null; then
        print_success "users.html exists in running pod"
    else
        print_error "users.html NOT found in running pod!"
    fi

    # Test routes
    print_info "Testing routes in pod..."
    kubectl exec $POD_NAME -n webapp -- wget -O- http://localhost:3000/dashboard &>/dev/null && print_success "/dashboard route works" || print_warning "/dashboard route failed"
    kubectl exec $POD_NAME -n webapp -- wget -O- http://localhost:3000/users &>/dev/null && print_success "/users route works" || print_warning "/users route failed"

else
    print_error "No running WebApp pods found!"
    kubectl get pods -n webapp -l app=webapp
    kubectl logs -l app=webapp -n webapp --tail=50
fi

# Test external connectivity
print_info "\nTesting external connectivity..."
sleep 5

SERVICE_TYPE=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.type}')
if [ "$SERVICE_TYPE" = "NodePort" ]; then
    NODE_PORT=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.ports[0].nodePort}')

    if curl -s -f "http://localhost:$NODE_PORT/health" &>/dev/null; then
        print_success "Health check passed!"

        # Test dashboard route
        if curl -s "http://localhost:$NODE_PORT/dashboard" | grep -q "Dashboard" &>/dev/null; then
            print_success "Dashboard route accessible"
        else
            print_warning "Dashboard route returned unexpected response"
        fi
    else
        print_warning "Health check failed, service might need more time"
    fi
fi

# Restore original deployment file
mv "$SCRIPT_DIR/k8s/webapp-deployment.yaml.bak" "$SCRIPT_DIR/k8s/webapp-deployment.yaml"

# ============================================
# Display Deployment Status
# ============================================
print_header "Deployment Complete!"

echo -e "\n${CYAN}Pod Status:${NC}"
kubectl get pods -n webapp

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
    print_info "Available Pages:"
    echo "  • Home:      http://localhost:$NODE_PORT/"
    echo "  • Register:  http://localhost:$NODE_PORT/register"
    echo "  • Login:     http://localhost:$NODE_PORT/login"
    echo "  • Dashboard: http://localhost:$NODE_PORT/dashboard"
    echo "  • Users:     http://localhost:$NODE_PORT/users"
    echo "  • Health:    http://localhost:$NODE_PORT/health"
    echo ""
    print_info "Test commands:"
    echo "  curl http://localhost:$NODE_PORT/dashboard"
    echo "  curl http://localhost:$NODE_PORT/users"
fi

if [ "$INGRESS_DEPLOYED" = true ]; then
    echo ""
    print_info "Ingress URL: http://localhost"
fi

# ============================================
# Useful Commands
# ============================================
print_header "Useful Commands"

cat << EOF
View logs:
  kubectl logs -f deployment/webapp -n webapp

View specific pod files:
  kubectl exec -it deployment/webapp -n webapp -- ls -la /app/public/

Test dashboard in pod:
  kubectl exec -it deployment/webapp -n webapp -- wget -O- http://localhost:3000/dashboard

View all resources:
  kubectl get all,ingress,pvc -n webapp

Test complete flow:
  # Register
  curl -X POST http://localhost:${NODE_PORT:-30080}/api/register \\
    -H "Content-Type: application/json" \\
    -d '{"name":"John Doe","email":"john@example.com","password":"password123"}'

  # Login (returns user data with name and email)
  curl -X POST http://localhost:${NODE_PORT:-30080}/api/login \\
    -H "Content-Type: application/json" \\
    -d '{"email":"john@example.com","password":"password123"}'

  # View all users
  curl http://localhost:${NODE_PORT:-30080}/api/users

  # Access dashboard page
  curl http://localhost:${NODE_PORT:-30080}/dashboard

Restart if needed:
  kubectl rollout restart deployment/webapp -n webapp

Cleanup:
  kubectl delete namespace webapp

Debug:
  # Check pod logs
  kubectl logs -l app=webapp -n webapp --all-containers=true

  # Describe pods
  kubectl describe pod -l app=webapp -n webapp

  # Get events
  kubectl get events -n webapp --sort-by='.lastTimestamp'
EOF

print_header "Next Steps"
echo "1. Open http://localhost:${NODE_PORT:-30080}/ in your browser"
echo "2. Register a new user"
echo "3. Login with registered credentials"
echo "4. You should be automatically redirected to the dashboard"
echo "5. Click 'View All Users' button to see the users list"

print_header "Deployment Script Completed Successfully"

echo -e "\n${GREEN}Image built with tag: $BUILD_TAG${NC}"
echo -e "${YELLOW}Note: Deployment YAML has been restored to use 'webapp:latest'${NC}"
