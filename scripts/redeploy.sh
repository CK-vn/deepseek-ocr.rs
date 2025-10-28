#!/bin/bash
# Redeploy DeepSeek-OCR with updated code

set -e

echo "=========================================="
echo "DeepSeek-OCR Redeployment Script"
echo "=========================================="
echo ""

# Check if we're in the right directory
if [ ! -f "Cargo.toml" ]; then
    echo "Error: Must run from project root directory"
    exit 1
fi

# Step 1: Commit changes
echo "Step 1: Committing changes to git..."
git add -A
git status
echo ""
read -p "Commit message (or press Enter for default): " COMMIT_MSG
if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="Update: Add default grounding mode for bounding boxes"
fi
git commit -m "$COMMIT_MSG" || echo "No changes to commit"
echo "✓ Changes committed"
echo ""

# Step 2: Push to remote
echo "Step 2: Pushing to remote repository..."
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"
read -p "Push to remote? (y/n): " PUSH_CONFIRM
if [ "$PUSH_CONFIRM" = "y" ]; then
    git push origin "$CURRENT_BRANCH"
    echo "✓ Pushed to remote"
else
    echo "⚠ Skipped push to remote"
fi
echo ""

# Step 3: Get current instance info
echo "Step 3: Getting current EC2 instance information..."
cd terraform
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "⚠ No running DeepSeek-OCR instance found"
    echo "The instance may be stopped by schedule or not yet created"
    echo ""
    read -p "Do you want to start the Auto Scaling Group? (y/n): " START_ASG
    if [ "$START_ASG" = "y" ]; then
        ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name 2>/dev/null)
        if [ -n "$ASG_NAME" ]; then
            echo "Setting desired capacity to 1..."
            aws autoscaling set-desired-capacity \
                --auto-scaling-group-name "$ASG_NAME" \
                --desired-capacity 1
            echo "✓ Auto Scaling Group starting..."
            echo "Waiting for instance to launch (this may take 2-3 minutes)..."
            sleep 30
            
            # Wait for instance
            for i in {1..12}; do
                INSTANCE_ID=$(aws ec2 describe-instances \
                    --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
                              "Name=instance-state-name,Values=running" \
                    --query 'Reservations[0].Instances[0].InstanceId' \
                    --output text 2>/dev/null || echo "")
                if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
                    echo "✓ Instance launched: $INSTANCE_ID"
                    break
                fi
                echo "  Waiting... ($i/12)"
                sleep 15
            done
        fi
    fi
fi

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "✗ Could not find or start instance"
    echo "Please check AWS console or start the instance manually"
    exit 1
fi

echo "✓ Found instance: $INSTANCE_ID"
echo ""

# Step 4: Trigger instance refresh
echo "Step 4: Triggering instance refresh..."
echo ""
echo "Choose deployment method:"
echo "  1) Instance Refresh (recommended) - Gradual replacement with health checks"
echo "  2) Terminate Instance - Immediate replacement (faster but brief downtime)"
echo "  3) Manual Update - SSH and update code on existing instance"
echo ""
read -p "Select method (1/2/3): " DEPLOY_METHOD

case $DEPLOY_METHOD in
    1)
        echo ""
        echo "Starting instance refresh..."
        ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name 2>/dev/null)
        
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
        echo ""
        echo "This will take approximately 5-10 minutes"
        ;;
        
    2)
        echo ""
        echo "Terminating current instance..."
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
        echo "✓ Instance terminating"
        echo ""
        echo "Auto Scaling Group will launch a new instance automatically"
        echo "This will take approximately 3-5 minutes"
        ;;
        
    3)
        echo ""
        echo "Manual update selected"
        echo ""
        
        # Get instance IP
        INSTANCE_IP=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        echo "Instance IP: $INSTANCE_IP"
        echo ""
        echo "SSH into the instance and run:"
        echo ""
        echo "  ssh -i deepseek-ocr-key.pem ubuntu@$INSTANCE_IP"
        echo "  cd deepseek-ocr.rs"
        echo "  git pull"
        echo "  cargo build --release --bin deepseek-ocr-server"
        echo "  sudo systemctl restart deepseek-ocr"
        echo ""
        read -p "Press Enter when done..."
        ;;
        
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac

cd ..

echo ""
echo "=========================================="
echo "Deployment initiated!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Wait for the new instance to be ready (check AWS console)"
echo "2. Verify the service is running:"
echo "   ./terraform/check_services.sh"
echo "3. Test the bounding box feature:"
echo "   ./test/run_bbox_test.sh"
echo ""
