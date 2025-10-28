#!/bin/bash
set -e

echo "=== Deploying Open WebUI Instance ==="
echo ""

# Navigate to terraform directory
cd "$(dirname "$0")"

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    echo "Initializing Terraform..."
    terraform init
fi

# Plan the deployment
echo ""
echo "Planning deployment..."
terraform plan -target=aws_instance.open_webui -target=aws_security_group.open_webui

# Ask for confirmation
read -p "Do you want to proceed with the deployment? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

# Apply the changes
echo ""
echo "Deploying Open WebUI instance..."
terraform apply -target=aws_instance.open_webui -target=aws_security_group.open_webui -auto-approve

# Get outputs
echo ""
echo "=== Deployment Complete ==="
echo ""
terraform output open_webui_url
terraform output open_webui_ssh_command
echo ""
echo "Note: It may take 2-3 minutes for Open WebUI to be fully ready."
echo "Check installation progress with:"
echo "  $(terraform output -raw open_webui_ssh_command)"
echo "  tail -f /var/log/user-data.log"
