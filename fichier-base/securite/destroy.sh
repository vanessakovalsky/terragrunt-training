#!/bin/bash

set -e

echo "🚀 Starting Terragrunt Hooks Exercise Deployment"
echo "=================================================="

# Variables
MODULES=("web-servers" "database" "security-groups-database" "security-groups" "vpc")
ROOT_DIR="environment/dev"


# Fonction de déploiement avec gestion d'erreurs
destroy_module() {
    local module=$1
    echo ""
    echo "📦 Destroying $module..."
    echo "------------------------"
    
    cd "$ROOT_DIR/$module"

    
    echo "✅ Running terragrunt destroy for $module..."
    terragrunt destroy
    
    cd - > /dev/null
    
    echo "✅ $module destroy successfully!"
}

# destroy séquentiel avec gestion des dépendances
for module in "${MODULES[@]}"; do
    destroy_module "$module"
done

echo ""
echo "🎉 All modules destroyed successfully!"
