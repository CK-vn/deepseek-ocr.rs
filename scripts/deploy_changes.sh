#!/bin/bash
# Complete deployment script for bounding box feature

set -e

echo "=========================================="
echo "DeepSeek-OCR Deployment Script"
echo "Bounding Box Feature"
echo "=========================================="
echo ""

# Step 1: Setup fork (if not already done)
echo "Step 1: Checking fork setup..."
if git remote | grep -q "^fork$"; then
    echo "✓ Fork remote exists"
    FORK_URL=$(git remote get-url fork)
    echo "  Fork URL: $FORK_URL"
else
    echo "Fork remote not found. Setting up..."
    ./scripts/setup_fork.sh
fi
echo ""

# Step 2: Ensure changes are pushed
echo "Step 2: Checking if changes are pushed..."
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"

# Check if there are unpushed commits
UNPUSHED=$(git log fork/$CURRENT_BRANCH..$CURRENT_BRANCH --oneline 2>/dev/null | wc -l || echo "0")
if [ "$UNPUSHED" -gt 0 ]; then
    echo "⚠ You have $UNPUSHED unpushed commit(s)"
    read -p "Push to fork now? (y/n): " PUSH_NOW
    if [ "$PUSH_NOW" = "y" ]; then
        git push fork "$CURRENT_BRANCH"
        echo "✓ Changes pushed"
    else
        echo "Please push changes before deploying"
        exit 1
    fi
else
    echo "✓ All changes are pushed"
fi
echo ""

# Step 3: Update Terraform configuration
echo "Step 3: Updating Terraform configuration..."
if grep -q "CK-vn/deepseek-ocr.rs" terraform/user-data.sh; then
    echo "✓ Terraform already configured to use your fork"
else
    echo "Updating Terraform to use your fork..."
    ./scripts/update_deployment_repo.sh
fi
echo ""

# Step 4: Choose deployment method
echo "Step 4: Choose deployment method"
echo "=========================================="
echo ""
echo "Choose how to deploy the changes:"
echo ""
echo "  1) Update existing instance (Quick, ~5-10 min)"
echo "     - SSH into running instance"
echo "     - Pull latest code from your fork"
echo "     - Rebuild and restart service"
echo "     - Minimal downtime (~30 seconds)"
echo ""
echo "  2) Create new instance (Clean, ~10-15 min)"
echo "     - Terminate current instance"
echo "     - Auto Scaling Group launches new instance"
echo "     - New instance pulls from your fork"
echo "     - Downtime: ~3-5 minutes"
echo ""
echo "  3) Instance Refresh (Production, ~15-20 min)"
echo "     - Gradual replacement with health checks"
echo "     - Zero downtime (if configured correctly)"
echo "     - Best for production environments"
echo ""
read -p "Select method (1/2/3): " DEPLOY_METHOD

case $DEPLOY_METHOD in
    1)
        echo ""
        echo "=========================================="
        echo "Method 1: Update Existing Instance"
        echo "=========================================="
        echo ""
        
        # Check if instance is running
        cd terraform
        INSTANCE_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || echo "")
        
        if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
            echo "✗ No running instance found"
            echo "Starting Auto Scaling Group..."
            ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name)
            aws autoscaling set-desired-capacity \
                --auto-scaling-group-name "$ASG_NAME" \
                --desired-capacity 1
            echo "Waiting for instance to start (60 seconds)..."
            sleep 60
        fi
        
        cd ..
        
        # Get instance IP
        INSTANCE_IP=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        echo "Instance IP: $INSTANCE_IP"
        echo ""
        
        # Create and execute update script
        cat > /tmp/update_deepseek.sh << UPDATESCRIPT
#!/bin/bash
set -e
echo "=== Updating DeepSeek-OCR ==="
cd /home/ubuntu/deepseek-ocr.rs

echo "Current repository:"
git remote -v | grep origin

echo ""
echo "Updating repository URL to fork..."
git remote set-url origin $FORK_URL
git fetch origin
git checkout $CURRENT_BRANCH
git pull origin $CURRENT_BRANCH

echo ""
echo "Rebuilding server..."
source \$HOME/.cargo/env
cargo build --release -p deepseek-ocr-server --features cuda

echo ""
echo "Restarting service..."
sudo systemctl restart deepseek-ocr-server
sleep 5

echo ""
echo "Service status:"
sudo systemctl status deepseek-ocr-server --no-pager

echo ""
echo "=== Update complete! ==="
UPDATESCRIPT

        echo "Uploading and executing update script..."
        scp -i terraform/deepseek-ocr-key.pem -o StrictHostKeyChecking=no /tmp/update_deepseek.sh ubuntu@$INSTANCE_IP:/tmp/
        ssh -i terraform/deepseek-ocr-key.pem -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP "chmod +x /tmp/update_deepseek.sh && /tmp/update_deepseek.sh"
        ;;
        
    2)
        echo ""
        echo "=========================================="
        echo "Method 2: Create New Instance"
        echo "=========================================="
        echo ""
        
        cd terraform
        
        # Get current instance
        INSTANCE_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
            echo "Terminating current instance: $INSTANCE_ID"
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
            echo "✓ Instance terminating"
        else
            echo "No running instance found, starting new one..."
            ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name)
            aws autoscaling set-desired-capacity \
                --auto-scaling-group-name "$ASG_NAME" \
                --desired-capacity 1
        fi
        
        echo ""
        echo "Auto Scaling Group will launch a new instance"
        echo "This will take approximately 5-10 minutes"
        echo ""
        echo "Monitor with:"
        echo "  watch -n 10 './terraform/check_services.sh'"
        
        cd ..
        ;;
        
    3)
        echo ""
        echo "=========================================="
        echo "Method 3: Instance Refresh"
        echo "=========================================="
        echo ""
        
        cd terraform
        ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name)
        
        echo "Starting instance refresh for: $ASG_NAME"
        aws autoscaling start-instance-refresh \
            --auto-scaling-group-name "$ASG_NAME" \
            --preferences '{
                "MinHealthyPercentage": 0,
                "InstanceWarmup": 300
            }'
        
        echo "✓ Instance refresh started"
        echo ""
        echo "Monitor progress with:"
        echo "  aws autoscaling describe-instance-refreshes --auto-scaling-group-name $ASG_NAME"
        
        cd ..
        ;;
        
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "Deployment Initiated!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Wait for deployment to complete"
echo "2. Verify service health:"
echo "   cd terraform && ./check_services.sh"
echo "3. Test bounding boxes:"
echo "   ./test/run_bbox_test.sh"
echo ""
