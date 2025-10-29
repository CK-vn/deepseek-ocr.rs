#!/bin/bash

# Script to create AMI snapshots of running instances for faster future boots

set -e

REGION="us-west-2"
DEEPSEEK_INSTANCE_ID="i-0bac65c190c113895"
OPENWEBUI_INSTANCE_ID="i-046e54fe60dab21ed"

echo "=== Creating AMI Snapshots ==="
echo ""
echo "This will create AMI snapshots of your running instances."
echo "Future deployments can use these AMIs for much faster startup times."
echo ""

# Check if instances are running
echo "Checking instance states..."
DEEPSEEK_STATE=$(aws ec2 describe-instances --instance-ids $DEEPSEEK_INSTANCE_ID --region $REGION --query 'Reservations[0].Instances[0].State.Name' --output text)
OPENWEBUI_STATE=$(aws ec2 describe-instances --instance-ids $OPENWEBUI_INSTANCE_ID --region $REGION --query 'Reservations[0].Instances[0].State.Name' --output text)

echo "DeepSeek OCR instance: $DEEPSEEK_STATE"
echo "Open WebUI instance: $OPENWEBUI_STATE"
echo ""

if [ "$DEEPSEEK_STATE" != "running" ] || [ "$OPENWEBUI_STATE" != "running" ]; then
    echo "ERROR: Both instances must be running to create AMIs"
    exit 1
fi

# Verify services are healthy
echo "Verifying services are healthy..."
if ! curl -s http://deepseek-ocr-alb-373415353.us-west-2.elb.amazonaws.com:8000/v1/health > /dev/null 2>&1; then
    echo "ERROR: DeepSeek OCR service is not responding"
    exit 1
fi

if ! curl -s http://open-webui-alb-2083930796.us-west-2.elb.amazonaws.com:3000/ > /dev/null 2>&1; then
    echo "ERROR: Open WebUI service is not responding"
    exit 1
fi

echo "✓ Both services are healthy"
echo ""

# Create AMI for DeepSeek OCR
echo "Creating AMI for DeepSeek OCR instance..."
DEEPSEEK_AMI_ID=$(aws ec2 create-image \
    --instance-id $DEEPSEEK_INSTANCE_ID \
    --name "deepseek-ocr-ready-$(date +%Y%m%d-%H%M%S)" \
    --description "DeepSeek OCR with CUDA, compiled binary, and model cached" \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=deepseek-ocr-ami},{Key=Purpose,Value=DeepSeek OCR Ready Image},{Key=Environment,Value=demo}]' \
    --region $REGION \
    --output text \
    --query 'ImageId')

echo "✓ DeepSeek OCR AMI created: $DEEPSEEK_AMI_ID"

# Create AMI for Open WebUI
echo "Creating AMI for Open WebUI instance..."
OPENWEBUI_AMI_ID=$(aws ec2 create-image \
    --instance-id $OPENWEBUI_INSTANCE_ID \
    --name "open-webui-ready-$(date +%Y%m%d-%H%M%S)" \
    --description "Open WebUI with Docker and container pre-configured" \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=open-webui-ami},{Key=Purpose,Value=Open WebUI Ready Image},{Key=Environment,Value=demo}]' \
    --region $REGION \
    --output text \
    --query 'ImageId')

echo "✓ Open WebUI AMI created: $OPENWEBUI_AMI_ID"
echo ""

# Wait for AMIs to be available
echo "Waiting for AMIs to be available (this may take 5-10 minutes)..."
echo "DeepSeek OCR AMI: $DEEPSEEK_AMI_ID"
echo "Open WebUI AMI: $OPENWEBUI_AMI_ID"
echo ""

aws ec2 wait image-available --image-ids $DEEPSEEK_AMI_ID --region $REGION &
DEEPSEEK_PID=$!

aws ec2 wait image-available --image-ids $OPENWEBUI_AMI_ID --region $REGION &
OPENWEBUI_PID=$!

wait $DEEPSEEK_PID
echo "✓ DeepSeek OCR AMI is ready"

wait $OPENWEBUI_PID
echo "✓ Open WebUI AMI is ready"

echo ""
echo "=== AMI Creation Complete ==="
echo ""
echo "To use these AMIs in future deployments, update terraform/variables.tf:"
echo ""
echo "variable \"deepseek_ocr_ami\" {"
echo "  description = \"AMI ID for DeepSeek OCR (pre-built)\""
echo "  type        = string"
echo "  default     = \"$DEEPSEEK_AMI_ID\""
echo "}"
echo ""
echo "variable \"open_webui_ami\" {"
echo "  description = \"AMI ID for Open WebUI (pre-built)\""
echo "  type        = string"
echo "  default     = \"$OPENWEBUI_AMI_ID\""
echo "}"
echo ""
echo "Then update terraform/main.tf to use these variables instead of the Ubuntu AMI lookup."
echo ""
echo "With these AMIs, future deployments will start in ~5 minutes instead of ~15 minutes!"
