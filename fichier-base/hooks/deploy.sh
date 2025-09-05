#!/bin/bash

set -e

echo "🚀 Starting Terragrunt Hooks Exercise Deployment"
echo "=================================================="

# Variables
MODULES=("vpc" "security-groups" "database" "web-servers")
ROOT_DIR="environment/dev"
S3_BUCKET="vanessa-state-bucket"  # À adapter

# Vérification du bucket et création si nécessaire  
echo "Checking S3 bucket exists..."                                                                                                                                                                                                           
aws s3 ls "s3://$S3_BUCKET" 2>&1 || aws s3api create-bucket --bucket $S3_BUCKET --create-bucket-configuration LocationConstraint=us-east-2

# Fonction de déploiement avec gestion d'erreurs
deploy_module() {
    local module=$1
    echo ""
    echo "📦 Deploying $module..."
    echo "------------------------"
    
    cd "$ROOT_DIR/$module"

    # Init
    echo "🔄 Running terragrunt init for $module..."
    terragrunt init
    
    # Hooks en action
    echo "🔄 Running terragrunt plan for $module..."
    terragrunt plan
    
    echo "✅ Running terragrunt apply for $module..."
    terragrunt apply -auto-approve
    
    cd - > /dev/null
    
    echo "✅ $module deployed successfully!"
}

# Déploiement séquentiel avec gestion des dépendances
for module in "${MODULES[@]}"; do
    deploy_module "$module"
done

echo ""
echo "🎉 All modules deployed successfully!"
echo "🌐 Check the web server URL in the final output"

# Test final
echo ""
echo "🧪 Running final tests..."
cd "$ROOT_DIR/web-servers"
WEB_IP=$(terragrunt output -raw public_ip)
echo "Testing web server at: http://$WEB_IP"
curl -s "http://$WEB_IP" | grep -q "Hooks Exercise" && echo "✅ Web server test passed!" || echo "❌ Web server test failed"