#!/bin/bash
# Update the running DeepSeek-OCR instance with latest code

set -e

echo "=========================================="
echo "DeepSeek-OCR Instance Update Script"
echo "=========================================="
echo ""

# Check if we're in terraform directory
if [ ! -f "terraform.tfstate" ]; then
    if [ -d "terraform" ]; then
        cd terraform
    else
        echo "Error: Cannot find terraform directory"
        exit 1
    fi
fi

# Get instance information
echo "Step 1: Finding DeepSeek-OCR instance..."
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "✗ No running DeepSeek-OCR instance found"
    echo ""
    echo "The instance may be stopped by schedule. Start it with:"
    echo "  ASG_NAME=\$(cd terraform && terraform output -raw deepseek_ocr_asg_name)"
    echo "  aws autoscaling set-desired-capacity --auto-scaling-group-name \$ASG_NAME --desired-capacity 1"
    exit 1
fi

INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "✓ Found instance: $INSTANCE_ID"
echo "✓ Instance IP: $INSTANCE_IP"
echo ""

# Check if SSH key exists
if [ ! -f "deepseek-ocr-key.pem" ]; then
    echo "✗ SSH key not found: deepseek-ocr-key.pem"
    echo "Please ensure the key file is in the terraform directory"
    exit 1
fi

chmod 400 deepseek-ocr-key.pem

# Test SSH connection
echo "Step 2: Testing SSH connection..."
if ! ssh -i deepseek-ocr-key.pem -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP "echo 'SSH connection successful'" 2>/dev/null; then
    echo "✗ Cannot connect to instance via SSH"
    echo "Please check:"
    echo "  1. Security group allows SSH from your IP"
    echo "  2. Instance is fully initialized"
    echo "  3. SSH key is correct"
    exit 1
fi
echo "✓ SSH connection successful"
echo ""

# Create update script
echo "Step 3: Creating update script..."
cat > /tmp/update_deepseek.sh << 'UPDATESCRIPT'
#!/bin/bash
set -e

echo "=== Updating DeepSeek-OCR on instance ==="
cd /home/ubuntu/deepseek-ocr.rs

echo "Step 1: Pulling latest code..."
git fetch origin
git reset --hard origin/master
git pull origin master

echo "Step 2: Rebuilding server..."
source $HOME/.cargo/env
cargo build --release -p deepseek-ocr-server --features cuda

echo "Step 3: Restarting service..."
sudo systemctl restart deepseek-ocr-server

echo "Step 4: Checking service status..."
sleep 5
sudo systemctl status deepseek-ocr-server --no-pager

echo ""
echo "=== Update complete! ==="
UPDATESCRIPT

# Copy and execute update script
echo "Step 4: Uploading and executing update script..."
scp -i deepseek-ocr-key.pem -o StrictHostKeyChecking=no /tmp/update_deepseek.sh ubuntu@$INSTANCE_IP:/tmp/
ssh -i deepseek-ocr-key.pem -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP "chmod +x /tmp/update_deepseek.sh && /tmp/update_deepseek.sh"

echo ""
echo "=========================================="
echo "Update Complete!"
echo "=========================================="
echo ""

# Get API endpoint
API_ENDPOINT=$(terraform output -raw deepseek_ocr_api_endpoint 2>/dev/null || echo "")
if [ -n "$API_ENDPOINT" ]; then
    echo "API Endpoint: $API_ENDPOINT"
    echo ""
    echo "Test the service:"
    echo "  curl $API_ENDPOINT/v1/health"
    echo ""
    echo "Test bounding boxes:"
    echo "  cd .. && ./test/run_bbox_test.sh"
fi

echo ""
