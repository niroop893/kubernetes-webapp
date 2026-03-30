#!/bin/bash

set -e

echo "========================================"
echo "  WebApp Kubernetes Deployment (Fixed)"
echo "========================================"

# Cleanup previous deployment
echo -e "\n[1/8] Cleaning up previous deployment..."
kubectl delete namespace webapp --ignore-not-found=true
sleep 5

# Pull MongoDB image
echo -e "\n[2/8] Pulling MongoDB image..."
docker pull mongo:7.0
if [ $? -ne 0 ]; then
    echo "Error: Failed to pull MongoDB image"
    exit 1
fi

# Build webapp image
echo -e "\n[3/8] Building WebApp Docker image..."
cd webapp
docker build -t webapp:latest .
if [ $? -ne 0 ]; then
    echo "Error: Docker build failed"
    exit 1
fi
cd ..

# Verify images
echo -e "\n[4/8] Verifying Docker images..."
docker images | grep -E "mongo|webapp"

# Create namespace
echo -e "\n[5/8] Creating namespace..."
kubectl apply -f k8s/namespace.yaml

# Deploy MongoDB
echo -e "\n[6/8] Deploying MongoDB..."
kubectl apply -f k8s/mongodb-secret.yaml
kubectl apply -f k8s/mongodb-configmap.yaml
kubectl apply -f k8s/mongodb-pvc.yaml
kubectl apply -f k8s/mongodb-deployment.yaml
kubectl apply -f k8s/mongodb-service.yaml

# Wait for MongoDB to be ready
echo -e "\n[7/8] Waiting for MongoDB to be ready (this may take 1-2 minutes)..."
for i in {1..24}; do
    STATUS=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    echo "  Attempt $i/24: MongoDB status is $STATUS"
    if [ "$STATUS" = "Running" ]; then
        echo "  MongoDB is running!"
        break
    fi
    sleep 5
done

# Check if MongoDB is actually ready
kubectl get pods -n webapp -l app=mongodb

# Deploy webapp
echo -e "\n[8/8] Deploying WebApp..."
kubectl apply -f k8s/webapp-deployment.yaml
kubectl apply -f k8s/webapp-service.yaml

# Wait for webapp to be ready
echo -e "\nWaiting for WebApp to be ready (this may take 1-2 minutes)..."
for i in {1..24}; do
    READY=$(kubectl get pods -n webapp -l app=webapp -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "Pending")
    echo "  Attempt $i/24: WebApp status is $READY"
    if [[ "$READY" == *"Running"* ]]; then
        echo "  WebApp is running!"
        break
    fi
    sleep 5
done

# Display status
echo -e "\n========================================"
echo "  Deployment Complete!"
echo "========================================"
echo -e "\nPod Status:"
kubectl get pods -n webapp

echo -e "\nService Status:"
kubectl get services -n webapp

echo -e "\n========================================"
echo "  Access Information"
echo "========================================"
echo "WebApp URL: http://localhost:30080"
echo -e "\nUseful commands:"
echo "  View all resources:    kubectl get all -n webapp"
echo "  View webapp logs:      kubectl logs -f deployment/webapp -n webapp"
echo "  View mongodb logs:     kubectl logs -f deployment/mongodb -n webapp"
echo "  Describe webapp pod:   kubectl describe pod -l app=webapp -n webapp"
echo "  Cleanup:               kubectl delete namespace webapp"
echo -e "\n========================================"
