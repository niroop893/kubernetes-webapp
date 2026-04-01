#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}========================================${NC}"; }
print_info() { echo -e "${CYAN}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

# Get pod names
WEBAPP_POD=$(kubectl get pods -n webapp -l app=webapp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
MONGO_POD=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Get MongoDB credentials from secret
MONGO_USER=$(kubectl get secret mongodb-secret -n webapp -o jsonpath='{.data.mongodb-root-username}' 2>/dev/null | base64 -d)
MONGO_PASS=$(kubectl get secret mongodb-secret -n webapp -o jsonpath='{.data.mongodb-root-password}' 2>/dev/null | base64 -d)

# Get service port
NODE_PORT=$(kubectl get svc webapp-service -n webapp -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

print_header "WebApp Statistics Dashboard"

if [ -z "$WEBAPP_POD" ] || [ -z "$MONGO_POD" ]; then
    print_error "Pods not found! Make sure the application is deployed."
    exit 1
fi

echo -e "\n${CYAN}Pod Information:${NC}"
echo "  WebApp Pod:  $WEBAPP_POD"
echo "  MongoDB Pod: $MONGO_POD"
echo "  Service Port: $NODE_PORT"
echo "  MongoDB User: $MONGO_USER"

print_header "API Statistics (via HTTP)"

print_info "\n[1] Total Registered Users:"
USERS_COUNT=$(curl -s http://localhost:$NODE_PORT/api/users 2>/dev/null | jq -r '.count // "N/A"' 2>/dev/null || echo "N/A")
echo "   $USERS_COUNT users"

print_info "\n[2] Currently Online Users:"
ONLINE_COUNT=$(curl -s http://localhost:$NODE_PORT/api/online-count 2>/dev/null | jq -r '.count // "N/A"' 2>/dev/null || echo "N/A")
echo "   $ONLINE_COUNT users online"

print_info "\n[3] Total Messages:"
MESSAGES_COUNT=$(curl -s http://localhost:$NODE_PORT/api/messages 2>/dev/null | jq -r '.count // "N/A"' 2>/dev/null || echo "N/A")
echo "   $MESSAGES_COUNT messages"

print_info "\n[4] Application Health:"
curl -s http://localhost:$NODE_PORT/health 2>/dev/null | jq '.' 2>/dev/null || echo "Unable to fetch health status"

print_info "\n[5] All Users Summary:"
curl -s http://localhost:$NODE_PORT/api/users 2>/dev/null | jq -r '.users[]? | "   - \(.name) (\(.email)) - Created: \(.createdAt // "N/A")"' 2>/dev/null || echo "Unable to fetch users"

print_info "\n[6] Recent Messages (Last 10):"
curl -s http://localhost:$NODE_PORT/api/messages 2>/dev/null | jq -r '.messages[-10:][]? | "   [\(.userName)] \(.message) - \(.timestamp)"' 2>/dev/null || echo "No messages found"

print_header "MongoDB Direct Queries"

print_info "\n[7] Database Collections:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin --eval "
db.getSiblingDB('webappdb').getCollectionNames()
" 2>/dev/null

print_info "\n[8] Users Collection - Count and Sample:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
print('Total Users:', db.users.countDocuments());
print('\nSample User Document:');
printjson(db.users.findOne());
" 2>/dev/null

print_info "\n[9] All Users with IDs and Timestamps:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
db.users.find({}, {name: 1, email: 1, createdAt: 1, lastLogin: 1}).forEach(function(user) {
    print('ID: ' + user._id);
    print('  Name: ' + user.name);
    print('  Email: ' + user.email);
    print('  Created: ' + user.createdAt);
    print('  Last Login: ' + (user.lastLogin || 'Never'));
    print('');
});
" 2>/dev/null

print_info "\n[10] Messages Collection - Count and Stats:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
var count = db.messages.countDocuments();
print('Total Messages:', count);

if (count > 0) {
    print('\nOldest Message:');
    var oldest = db.messages.find().sort({timestamp: 1}).limit(1).toArray()[0];
    if (oldest) {
        print('  Time:', oldest.timestamp);
        print('  User:', oldest.userName);
        print('  Message:', oldest.message);
    }
    
    print('\nNewest Message:');
    var newest = db.messages.find().sort({timestamp: -1}).limit(1).toArray()[0];
    if (newest) {
        print('  Time:', newest.timestamp);
        print('  User:', newest.userName);
        print('  Message:', newest.message);
    }
}
" 2>/dev/null

print_info "\n[11] All Messages with IDs and Timestamps (Last 20):"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
var messages = db.messages.find().sort({timestamp: -1}).limit(20).toArray();
if (messages.length === 0) {
    print('No messages found');
} else {
    messages.forEach(function(msg) {
        print('ID: ' + msg._id);
        print('  User: ' + msg.userName + ' (' + msg.email + ')');
        print('  Message: ' + msg.message);
        print('  Time: ' + msg.timestamp);
        print('');
    });
}
" 2>/dev/null

print_info "\n[12] Users Activity Statistics:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
print('Users with Last Login:');
db.users.find({lastLogin: {\$exists: true}}).sort({lastLogin: -1}).forEach(function(user) {
    print('  - ' + user.name + ': ' + user.lastLogin);
});

print('\nUsers without Last Login:');
var neverLoggedIn = db.users.find({lastLogin: {\$exists: false}}).count();
print('  Count:', neverLoggedIn);
" 2>/dev/null

print_info "\n[13] Messages by User:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
var results = db.messages.aggregate([
    {\$group: {
        _id: '\$userName',
        count: {\$sum: 1},
        lastMessage: {\$max: '\$timestamp'}
    }},
    {\$sort: {count: -1}}
]).toArray();

if (results.length === 0) {
    print('No messages found');
} else {
    results.forEach(function(result) {
        print(result._id + ': ' + result.count + ' messages (last: ' + result.lastMessage + ')');
    });
}
" 2>/dev/null

print_header "Kubernetes Resources"

print_info "\n[14] Pod Status and Resource Usage:"
kubectl get pods -n webapp -o wide
echo ""
kubectl top pods -n webapp 2>/dev/null || echo "  (Metrics not available - metrics-server not installed)"

print_info "\n[15] Service Details:"
kubectl get services -n webapp -o wide

print_info "\n[16] Service Endpoints:"
kubectl get endpoints -n webapp

print_info "\n[17] PVC Status:"
kubectl get pvc -n webapp

print_info "\n[18] ConfigMaps and Secrets:"
echo "ConfigMaps:"
kubectl get configmap -n webapp
echo -e "\nSecrets:"
kubectl get secrets -n webapp

print_info "\n[19] Ingress Status:"
kubectl get ingress -n webapp 2>/dev/null || echo "  No ingress configured"

print_info "\n[20] Recent Pod Events:"
kubectl get events -n webapp --sort-by='.lastTimestamp' | tail -10

print_info "\n[21] Recent WebApp Logs (Last 15 lines):"
kubectl logs $WEBAPP_POD -n webapp --tail=15 2>/dev/null || echo "Unable to fetch logs"

print_info "\n[22] Recent MongoDB Logs (Last 10 lines):"
kubectl logs $MONGO_POD -n webapp --tail=10 2>/dev/null || echo "Unable to fetch logs"

print_header "Database Indexes"

print_info "\n[23] Users Collection Indexes:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
printjson(db.users.getIndexes())
" 2>/dev/null

print_info "\n[24] Messages Collection Indexes:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
printjson(db.messages.getIndexes())
" 2>/dev/null

print_info "\n[25] Database Stats:"
kubectl exec $MONGO_POD -n webapp -- mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --authenticationDatabase admin webappdb --eval "
var stats = db.stats();
print('Database: ' + stats.db);
print('Collections: ' + stats.collections);
print('Data Size: ' + (stats.dataSize / 1024 / 1024).toFixed(2) + ' MB');
print('Storage Size: ' + (stats.storageSize / 1024 / 1024).toFixed(2) + ' MB');
print('Indexes: ' + stats.indexes);
print('Index Size: ' + (stats.indexSize / 1024).toFixed(2) + ' KB');
" 2>/dev/null

print_header "Summary Dashboard"

# Calculate stats
TOTAL_USERS=$(curl -s http://localhost:$NODE_PORT/api/users 2>/dev/null | jq -r '.count // 0' 2>/dev/null || echo "0")
ONLINE_USERS=$(curl -s http://localhost:$NODE_PORT/api/online-count 2>/dev/null | jq -r '.count // 0' 2>/dev/null || echo "0")
TOTAL_MESSAGES=$(curl -s http://localhost:$NODE_PORT/api/messages 2>/dev/null | jq -r '.count // 0' 2>/dev/null || echo "0")

echo ""
echo "╔════════════════════════════════════════╗"
echo "║         WebApp Statistics              ║"
echo "╠════════════════════════════════════════╣"
printf "║ Total Users:       %-19s ║\n" "$TOTAL_USERS"
printf "║ Online Users:      %-19s ║\n" "$ONLINE_USERS"
printf "║ Total Messages:    %-19s ║\n" "$TOTAL_MESSAGES"
printf "║ WebApp URL:        %-19s ║\n" "localhost:$NODE_PORT"
echo "╚════════════════════════════════════════╝"

print_header "Quick Commands Reference"

cat << 'EOF'

📊 API Commands:
  # Get all users
  curl http://localhost:30080/api/users | jq '.'

  # Get users count only
  curl http://localhost:30080/api/users | jq '.count'

  # Get specific user by name
  curl http://localhost:30080/api/users | jq '.users[] | select(.name=="John")'

  # Get online count
  curl http://localhost:30080/api/online-count | jq '.'

  # Get messages
  curl http://localhost:30080/api/messages | jq '.'

  # Get messages count
  curl http://localhost:30080/api/messages | jq '.count'

  # Get health
  curl http://localhost:30080/health | jq '.'

🔍 MongoDB Direct Queries:
  # Set variables first
  MONGO_POD=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].metadata.name}')

  # Connect to MongoDB shell interactively
  kubectl exec -it $MONGO_POD -n webapp -- mongosh -u admin -p password123 --authenticationDatabase admin webappdb

  # Count users
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.countDocuments()"

  # List all users with name and email
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.find({}, {name: 1, email: 1, createdAt: 1}).pretty()"

  # Find user by email
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.findOne({email: 'user@example.com'})"

  # Find user by name
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.findOne({name: 'John Doe'})"

  # Get user by ID
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.findOne({_id: ObjectId('YOUR_ID_HERE')})"

  # Count messages
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.countDocuments()"

  # Get last 10 messages
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.find().sort({timestamp: -1}).limit(10).pretty()"

  # Get messages by specific user
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.find({userName: 'John Doe'}).pretty()"

  # Count messages by user
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.aggregate([{\$group: {_id: '\$userName', count: {\$sum: 1}}}, {\$sort: {count: -1}}])"

  # Get messages in date range
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.find({timestamp: {\$gte: new Date('2024-01-01'), \$lt: new Date('2024-12-31')}}).count()"

  # Get message by ID
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.findOne({_id: ObjectId('YOUR_ID_HERE')})"

☸️ Kubernetes Commands:
  # View all resources
  kubectl get all -n webapp
  kubectl get all,ingress,pvc,configmap,secret -n webapp

  # View logs (follow mode)
  kubectl logs -f deployment/webapp -n webapp
  kubectl logs -f deployment/mongodb -n webapp

  # View logs from all webapp pods
  kubectl logs -l app=webapp -n webapp --all-containers=true

  # View logs with timestamps
  kubectl logs deployment/webapp -n webapp --timestamps

  # Describe pods for troubleshooting
  kubectl describe pod -l app=webapp -n webapp
  kubectl describe pod -l app=mongodb -n webapp

  # Check resource usage
  kubectl top pods -n webapp
  kubectl top nodes

  # Port forward for testing
  kubectl port-forward svc/webapp-service 8080:80 -n webapp

  # Scale webapp
  kubectl scale deployment/webapp --replicas=3 -n webapp
  kubectl scale deployment/webapp --replicas=1 -n webapp

  # Restart deployments
  kubectl rollout restart deployment/webapp -n webapp
  kubectl rollout restart deployment/mongodb -n webapp

  # Check rollout status
  kubectl rollout status deployment/webapp -n webapp

  # Get pod shell
  kubectl exec -it deployment/webapp -n webapp -- /bin/sh
  kubectl exec -it deployment/mongodb -n webapp -- /bin/bash

  # Copy file from pod
  kubectl cp webapp/PODNAME:/app/package.json ./package.json -n webapp

  # Run command in pod
  kubectl exec deployment/webapp -n webapp -- ls -la /app

  # View environment variables in pod
  kubectl exec deployment/webapp -n webapp -- env

🗑️ Data Management Commands:
  # Backup MongoDB data
  kubectl exec $MONGO_POD -n webapp -- mongodump -u admin -p password123 --authenticationDatabase admin --db webappdb --out /tmp/backup

  # Delete specific message by ID
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.deleteOne({_id: ObjectId('YOUR_ID')})"

  # Delete messages by user
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.deleteMany({userName: 'John Doe'})"

  # Clear all messages (keep collection)
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.messages.deleteMany({})"

  # Delete user by email
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.deleteOne({email: 'user@example.com'})"

  # Update user information
  kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "db.users.updateOne({email: 'user@example.com'}, {\$set: {name: 'New Name'}})"

📈 Monitoring Commands:
  # Watch pods in real-time
  watch kubectl get pods -n webapp

  # Watch resource usage
  watch kubectl top pods -n webapp

  # Stream logs from multiple pods
  kubectl logs -f -l app=webapp -n webapp --all-containers=true --max-log-requests=10

  # Get events sorted by time
  kubectl get events -n webapp --sort-by='.lastTimestamp'

  # Check pod restart count
  kubectl get pods -n webapp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

🔧 Troubleshooting:
  # Check why pod is not running
  kubectl describe pod POD_NAME -n webapp
  kubectl logs POD_NAME -n webapp
  kubectl logs POD_NAME -n webapp --previous  # logs from previous container

  # Check service endpoints
  kubectl get endpoints -n webapp

  # Test connectivity from inside pod
  kubectl exec deployment/webapp -n webapp -- wget -O- http://localhost:3000/health
  kubectl exec deployment/webapp -n webapp -- wget -O- http://mongodb-service:27017

  # Check DNS resolution
  kubectl exec deployment/webapp -n webapp -- nslookup mongodb-service

  # Check if MongoDB is accessible
  kubectl exec deployment/webapp -n webapp -- nc -zv mongodb-service 27017

EOF

print_header "Additional Statistics Scripts"

# Create individual stat scripts
echo ""
print_info "Creating individual stat scripts..."

# Create users stats script
cat > /tmp/get-users.sh << 'EOFSCRIPT'
#!/bin/bash
MONGO_POD=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].metadata.name}')
kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "
print('=== ALL USERS ===\n');
db.users.find({}, {password: 0}).forEach(function(user) {
    print('ID:', user._id);
    print('Name:', user.name);
    print('Email:', user.email);
    print('Created:', user.createdAt);
    print('Last Login:', user.lastLogin || 'Never');
    print('---');
});
print('\nTotal Users:', db.users.countDocuments());
"
EOFSCRIPT

# Create messages stats script
cat > /tmp/get-messages.sh << 'EOFSCRIPT'
#!/bin/bash
MONGO_POD=$(kubectl get pods -n webapp -l app=mongodb -o jsonpath='{.items[0].metadata.name}')
kubectl exec $MONGO_POD -n webapp -- mongosh -u admin -p password123 --quiet --authenticationDatabase admin webappdb --eval "
print('=== ALL MESSAGES ===\n');
db.messages.find().sort({timestamp: 1}).forEach(function(msg) {
    print('ID:', msg._id);
    print('User:', msg.userName, '(' + msg.email + ')');
    print('Message:', msg.message);
    print('Time:', msg.timestamp);
    print('---');
});
print('\nTotal Messages:', db.messages.countDocuments());
"
EOFSCRIPT

chmod +x /tmp/get-users.sh /tmp/get-messages.sh

print_success "Created /tmp/get-users.sh - Run to see all users"
print_success "Created /tmp/get-messages.sh - Run to see all messages"

print_header "Script Completed"
echo ""
print_info "Run this script anytime with: ./stats.sh"
print_info "For live updates, use: watch -n 5 ./stats.sh"
echo ""
