#!/bin/bash
set -e

echo "=== Open WebUI Deployment Verification ==="
echo ""

# Get instance ID
INSTANCE_ID=$(cd terraform && terraform output -raw open_webui_instance_id 2>/dev/null)
WEBUI_URL=$(cd terraform && terraform output -raw open_webui_url 2>/dev/null)
DEEPSEEK_IP=$(cd terraform && terraform output -raw public_ip 2>/dev/null)

echo "Instance ID: $INSTANCE_ID"
echo "Open WebUI URL: $WEBUI_URL"
echo ""

# Check Docker container status
echo "Checking Docker container status..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region us-west-2 \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters command="sudo docker ps --filter name=open-webui"

echo ""
echo "Checking Open WebUI accessibility..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$WEBUI_URL")
if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Open WebUI is accessible (HTTP $HTTP_CODE)"
else
    echo "✗ Open WebUI returned HTTP $HTTP_CODE"
fi

echo ""
echo "Checking DeepSeek OCR connectivity from Open WebUI instance..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region us-west-2 \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters command="curl -s -o /dev/null -w 'DeepSeek OCR HTTP Status: %{http_code}\n' http://172.31.29.165:8000/"

echo ""
echo "=== Verification Complete ==="
echo ""
echo "Next Steps:"
echo "1. Open your browser and go to: $WEBUI_URL"
echo "2. Create an admin account (first user becomes admin)"
echo "3. Go to Settings > Connections"
echo "4. Add OpenAI API connection:"
echo "   - Base URL: http://172.31.29.165:8000"
echo "   - API Key: dummy-key (or any value)"
echo "5. Test DeepSeek OCR with image uploads!"
