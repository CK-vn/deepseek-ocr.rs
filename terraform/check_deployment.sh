#!/bin/bash
# Script to monitor deepseek-ocr deployment status

INSTANCE_ID="i-0c62beba89ff9c9c4"
REGION="us-west-2"
API_ENDPOINT="http://18.236.82.16:8000"

echo "=== DeepSeek OCR Deployment Monitor ==="
echo "Instance ID: $INSTANCE_ID"
echo "API Endpoint: $API_ENDPOINT"
echo ""

# Function to run SSM command and get output
run_ssm_command() {
    local command=$1
    local cmd_id=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name 'AWS-RunShellScript' \
        --parameters "commands=[\"$command\"]" \
        --region "$REGION" \
        --output json | jq -r '.Command.CommandId')
    
    sleep 3
    
    aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --output json | jq -r '.StandardOutputContent'
}

echo "1. Checking if user-data script is complete..."
run_ssm_command "grep 'User data script completed' /var/log/user-data.log || echo 'Still running...'"
echo ""

echo "2. Checking service status..."
run_ssm_command "systemctl is-active deepseek-ocr-server.service || echo 'Service not active'"
echo ""

echo "3. Checking last 20 lines of user-data log..."
run_ssm_command "tail -n 20 /var/log/user-data.log"
echo ""

echo "4. Checking service logs (if service is running)..."
run_ssm_command "tail -n 20 /var/log/deepseek-ocr-server.log 2>/dev/null || echo 'No service logs yet'"
echo ""

echo "5. Testing API endpoint..."
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "$API_ENDPOINT/v1/models" || echo "API not responding yet"
echo ""

echo "=== To manually check logs, use: ==="
echo "aws ssm start-session --target $INSTANCE_ID --region $REGION"
