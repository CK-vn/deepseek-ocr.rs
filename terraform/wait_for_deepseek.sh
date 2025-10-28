#!/bin/bash
# Script to monitor DeepSeek OCR service startup

set -e

REGION="us-west-2"
INSTANCE_ID="i-0ded7804308f1502f"
MAX_WAIT=1800  # 30 minutes
CHECK_INTERVAL=30

echo "=========================================="
echo "Monitoring DeepSeek OCR Service Startup"
echo "=========================================="
echo "Instance: $INSTANCE_ID"
echo "Max wait time: $((MAX_WAIT / 60)) minutes"
echo ""

start_time=$(date +%s)

check_service() {
    local cmd_id=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["systemctl is-active deepseek-ocr-server.service 2>/dev/null || echo inactive"]' \
        --region "$REGION" \
        --output json | jq -r '.Command.CommandId')
    
    sleep 3
    
    local status=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null | tr -d '\n')
    
    echo "$status"
}

check_build_progress() {
    local cmd_id=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["if pgrep -f \"cargo build\" > /dev/null; then echo building; elif [ -f /home/ubuntu/deepseek-ocr.rs/target/release/deepseek-ocr-server ]; then echo built; else echo starting; fi"]' \
        --region "$REGION" \
        --output json | jq -r '.Command.CommandId')
    
    sleep 3
    
    local status=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null | tr -d '\n')
    
    echo "$status"
}

while true; do
    elapsed=$(($(date +%s) - start_time))
    
    if [ $elapsed -gt $MAX_WAIT ]; then
        echo ""
        echo "❌ Timeout reached after $((elapsed / 60)) minutes"
        echo "Service did not start within expected time."
        echo ""
        echo "Check logs with:"
        echo "  aws ssm send-command --instance-ids $INSTANCE_ID --document-name 'AWS-RunShellScript' --parameters 'commands=[\"tail -200 /var/log/user-data.log\"]' --region $REGION"
        exit 1
    fi
    
    echo -n "[$(date +%H:%M:%S)] Elapsed: $((elapsed / 60))m $((elapsed % 60))s - "
    
    build_status=$(check_build_progress)
    
    case "$build_status" in
        "starting")
            echo "Status: Installing dependencies..."
            ;;
        "building")
            echo "Status: Building Rust binary (this takes 15-25 min)..."
            ;;
        "built")
            service_status=$(check_service)
            if [ "$service_status" = "active" ]; then
                echo "Status: ✅ Service is ACTIVE!"
                echo ""
                echo "=========================================="
                echo "DeepSeek OCR is now running!"
                echo "=========================================="
                echo ""
                echo "Testing endpoint..."
                sleep 5
                
                ALB_DNS=$(terraform -chdir=terraform output -raw deepseek_ocr_alb_dns 2>/dev/null)
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://${ALB_DNS}:8000/v1/models" || echo "000")
                
                if [ "$HTTP_CODE" = "200" ]; then
                    echo "✅ Service is accessible via ALB!"
                    echo "   URL: http://${ALB_DNS}:8000"
                else
                    echo "⚠️  Service running but ALB health check may take 1-2 minutes"
                    echo "   URL: http://${ALB_DNS}:8000"
                fi
                
                exit 0
            else
                echo "Status: Binary built, starting service..."
            fi
            ;;
        *)
            echo "Status: Unknown ($build_status)"
            ;;
    esac
    
    sleep $CHECK_INTERVAL
done
