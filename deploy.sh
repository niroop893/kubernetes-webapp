#!/bin/bash

set -e

echo "========================================"
echo "  WebApp Kubernetes Deployment"
echo "========================================"

# Check if ingress-nginx is installed
echo -e "\n[1/10] Checking Ingress Controller..."
if ! kubectl get namespace ingress-nginx &> /dev/null; then
    echo "Installing NGINX Ingress Controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
    
    echo "Waiting for Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=120s
else
    echo "✓ Ingress Controller already installed"
fi

# Cleanup previous deployment
echo -e "\n[2/10] Cleaning up previous deployment..."
kubectl delete namespace webapp --ignore-not-found=true
sleep 5

# Pull MongoDB image
echo -e "\n[3/10] Pulling MongoDB image..."
docker pull mongo:7.0
if [ $? -ne 0 ]; then
    echo "Error: Failed to pull MongoDB image"
    exit 1
fi

# Build webapp image
echo -e "\n[4/10] Building WebApp Docker image..."
cd webapp-k8s/webapp
docker build -t webapp:v2 .
if [ $? -ne 0 ]; then
    echo "Error: Docker build failed"
    exit 1
fi
cd ../..

# Verify images
echo -e "\n[5/10] Verifying Docker images..."
docker images | grep -E "mongo|webapp"

# Create namespace
echo -e "\n[6/10] Creating namespace..."
kubectl apply -f webapp-k8s/k8s/namespace.yaml

# Deploy MongoDB
echo -e "\n[7/10] Deploying MongoDB..."
kubectl apply -f webapp-k8s/k8s/mongodb-secret.yaml
kubectl apply -f webapp-k8s/k8s/mongodb-configmap.yaml
kubectl apply -f webapp-k8s/k8s/mongodb-pvc.yaml
kubectl apply -f webapp-k8s/k8s/mongodb-deployment.yaml
kubectl apply -f webapp-k8s/k8s/mongodb-service.yaml

# Wait for MongoDB to be ready
echo -e "\n[8/10] Waiting for MongoDB to be ready..."
kubectl wait --for=condition=ready pod -l app=mongodb -n webapp --timeout=120s
echo "✓ MongoDB is ready!"

# Deploy webapp
echo -e "\n[9/10] Deploying WebApp..."
kubectl apply -f webapp-k8s/k8s/webapp-deployment.yaml
kubectl apply -f webapp-k8s/k8s/webapp-service.yaml

# Wait for webapp to be ready
echo -e "\nWaiting for WebApp to be ready..."
kubectl wait --for=condition=ready pod -l app=webapp -n webapp --timeout=120s
echo "✓ WebApp is ready!"

# Deploy Ingress
echo -e "\n[10/10] Deploying Ingress..."
kubectl apply -f webapp-k8s/k8s/webapp-ingress.yaml
sleep 5

# Display status
echo -e "\n========================================"
echo "  Deployment Complete!"
echo "========================================"

echo -e "\nPod Status:"
kubectl get pods -n webapp

echo -e "\nService Status:"
kubectl get services -n webapp

echo -e "\nIngress Status:"
kubectl get ingress -n webapp

echo -e "\n========================================"
echo "  Access Information"
echo "========================================"
echo "✓ WebApp URL: http://localhost"
echo ""
echo "Test commands:"
echo "  curl http://localhost"
echo "  curl http://localhost/health"
echo ""
echo "Ingress URL: http://localhost (if ingress controller is configured)"
echo ""
echo "========================================"
echo "  Useful Commands"
echo "========================================"
echo "View all resources:"
echo "  kubectl get all -n webapp"
echo ""
echo "View webapp logs:"
echo "  kubectl logs -f deployment/webapp -n webapp"
echo ""
echo "View mongodb logs:"
echo "  kubectl logs -f deployment/mongodb -n webapp"
echo ""
echo "Describe webapp pod:"
echo "  kubectl describe pod -l app=webapp -n webapp"
echo ""
echo "View ingress details:"
echo "  kubectl describe ingress webapp-ingress -n webapp"
echo ""
echo "Test API:"
echo "  # Register user"
echo "  curl -X POST http://localhost/api/register \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"name\":\"Test User\",\"email\":\"test@example.com\",\"password\":\"password123\"}'"
echo ""
echo "  # Login"
echo "  curl -X POST http://localhost/api/login \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"email\":\"test@example.com\",\"password\":\"password123\"}'"
echo ""
echo "Cleanup:"
echo "  kubectl delete namespace webapp"
echo ""
echo "Restart webapp:"
echo "  kubectl rollout restart deployment/webapp -n webapp"
echo ""
echo "Scale webapp:"
echo "  kubectl scale deployment/webapp --replicas=3 -n webapp"
echo ""
echo "Execute into pod:"
echo "  kubectl exec -it deployment/webapp -n webapp -- /bin/sh"
echo ""
echo "========================================"
echo "  Deployment Script Completed Successfully"
echo "========================================"
