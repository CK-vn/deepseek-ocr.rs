#!/bin/bash

# Script to verify both services are fully operational

set -e

DEEPSEEK_ENDPOINT="http://deepseek-ocr-alb-373415353.us-west-2.elb.amazonaws.com:8000"
OPENWEBUI_ENDPOINT="http://open-webui-alb-2083930796.us-west-2.elb.amazonaws.com:3000"
MAX_WAIT=900  # 15 minutes
CHECK_INTERVAL=15

echo "=== Service Readiness Verification ==="
echo ""
echo "This script will wait for both services to become fully operational."
echo "Maximum wait time: $((MAX_WAIT/60)) minutes"
echo ""

# Function to check service
check_service() {
    local name=$1
    local url=$2
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" --max-time 10 2>/dev/null || echo "000")
    echo "$http_code"
}

# Wait for DeepSeek OCR
echo "Checking DeepSeek OCR service..."
elapsed=0
deepseek_ready=false

while [ $elapsed -lt $MAX_WAIT ]; do
    status=$(check_service "DeepSeek OCR" "$DEEPSEEK_ENDPOINT/v1/health")
    
    if [ "$status" = "200" ]; then
        echo "✓ DeepSeek OCR is ready! (took $elapsed seconds)"
        deepseek_ready=true
        break
    else
        printf "\r[%02d:%02d] DeepSeek OCR status: %s - waiting..." $((elapsed/60)) $((elapsed%60)) "$status"
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    fi
done

if [ "$deepseek_ready" = false ]; then
    echo ""
    echo "✗ DeepSeek OCR did not become ready within $((MAX_WAIT/60)) minutes"
    echo "Check the instance logs for issues"
    exit 1
fi

echo ""

# Wait for Open WebUI
echo "Checking Open WebUI service..."
elapsed=0
openwebui_ready=false

while [ $elapsed -lt $MAX_WAIT ]; do
    status=$(check_service "Open WebUI" "$OPENWEBUI_ENDPOINT/")
    
    if [ "$status" = "200" ]; then
        echo "✓ Open WebUI is ready! (took $elapsed seconds)"
        openwebui_ready=true
        break
    else
        printf "\r[%02d:%02d] Open WebUI status: %s - waiting..." $((elapsed/60)) $((elapsed%60)) "$status"
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
    fi
done

if [ "$openwebui_ready" = false ]; then
    echo ""
    echo "✗ Open WebUI did not become ready within $((MAX_WAIT/60)) minutes"
    echo "Check the instance logs for issues"
    exit 1
fi

echo ""
echo "=== All Services Ready ==="
echo ""
echo "DeepSeek OCR API: $DEEPSEEK_ENDPOINT"
echo "Open WebUI: $OPENWEBUI_ENDPOINT"
echo ""
echo "Test DeepSeek OCR:"
echo "  curl $DEEPSEEK_ENDPOINT/v1/models"
echo ""
echo "Access Open WebUI in your browser:"
echo "  $OPENWEBUI_ENDPOINT"
echo ""
echo "✓ Deployment successful!"
