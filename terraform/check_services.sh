#!/bin/bash
# Script to check the status of both services

set -e

REGION="us-west-2"

echo "=========================================="
echo "Checking Service Status"
echo "=========================================="
echo ""

# Get outputs
echo "Getting Terraform outputs..."
DEEPSEEK_ALB=$(terraform -chdir=terraform output -raw deepseek_ocr_alb_dns 2>/dev/null || echo "")
OPENWEBUI_ALB=$(terraform -chdir=terraform output -raw open_webui_alb_dns 2>/dev/null || echo "")
DEEPSEEK_ENDPOINT=$(terraform -chdir=terraform output -raw deepseek_ocr_api_endpoint 2>/dev/null || echo "")
OPENWEBUI_URL=$(terraform -chdir=terraform output -raw open_webui_url 2>/dev/null || echo "")

echo ""
echo "=========================================="
echo "ALB DNS Names (Persistent)"
echo "=========================================="
echo "DeepSeek OCR ALB: $DEEPSEEK_ALB"
echo "Open WebUI ALB:   $OPENWEBUI_ALB"
echo ""

# Check instances
echo "=========================================="
echo "Running Instances"
echo "=========================================="
aws ec2 describe-instances \
  --filters 'Name=tag:Environment,Values=demo' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
  --output table \
  --region $REGION

echo ""
echo "=========================================="
echo "Target Health Status"
echo "=========================================="

# Get target group ARNs
DEEPSEEK_TG=$(aws elbv2 describe-target-groups --region $REGION --query 'TargetGroups[?TargetGroupName==`deepseek-ocr-tg`].TargetGroupArn' --output text)
OPENWEBUI_TG=$(aws elbv2 describe-target-groups --region $REGION --query 'TargetGroups[?TargetGroupName==`open-webui-tg`].TargetGroupArn' --output text)

echo "DeepSeek OCR Target Group:"
aws elbv2 describe-target-health --target-group-arn "$DEEPSEEK_TG" --region $REGION \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table

echo ""
echo "Open WebUI Target Group:"
aws elbv2 describe-target-health --target-group-arn "$OPENWEBUI_TG" --region $REGION \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table

echo ""
echo "=========================================="
echo "Testing Public Access"
echo "=========================================="

echo -n "Open WebUI (${OPENWEBUI_URL}): "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$OPENWEBUI_URL" || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ ACCESSIBLE (HTTP $HTTP_CODE)"
else
  echo "✗ NOT ACCESSIBLE (HTTP $HTTP_CODE)"
fi

echo -n "DeepSeek OCR (${DEEPSEEK_ENDPOINT}): "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "${DEEPSEEK_ENDPOINT}/health" || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
  echo "✓ ACCESSIBLE (HTTP $HTTP_CODE)"
else
  echo "✗ NOT ACCESSIBLE (HTTP $HTTP_CODE)"
fi

echo ""
echo "=========================================="
echo "Access URLs"
echo "=========================================="
echo "Open WebUI:      $OPENWEBUI_URL"
echo "DeepSeek OCR:    $DEEPSEEK_ENDPOINT"
echo ""
echo "Note: DeepSeek OCR may take 10-15 minutes to download models and start."
echo "      Check logs with: aws ssm send-command --instance-ids <instance-id> --document-name 'AWS-RunShellScript' --parameters 'commands=[\"tail -100 /var/log/user-data.log\"]' --region $REGION"
