# Enhanced DeepSeek OCR Terraform Deployment

This directory contains the Terraform configuration for deploying the enhanced DeepSeek OCR server with multimodal support (image + text prompts).

## Key Differences from Original Deployment

1. **Feature Branch**: Deploys code from `feature/multimodal-ocr-with-bbox` branch
2. **Resource Naming**: All resources prefixed with `enhanced-` to avoid conflicts
3. **Separate Infrastructure**: Completely isolated from the original deployment
4. **Enhanced Tags**: All resources tagged with `Deployment: enhanced`
5. **Bug Fix**: Fixed "prompt/image embedding mismatch" error when uploading image with text in single turn

## What's Deployed

- **Enhanced DeepSeek OCR Server**: EC2 instance (g6.xlarge) with GPU running the enhanced server
- **Enhanced Open WebUI**: EC2 instance (t3.medium) for testing the API
- **Application Load Balancers**: Separate ALBs for both services
- **Lambda Scheduler**: Automated start/stop scheduling (9 AM - 7 PM UTC+7)

## Quick Start

```bash
# Initialize Terraform
cd terraform-enhanced
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply

# Wait for services to be ready (~15-20 minutes)
# Monitor progress via CloudWatch Logs or SSM Session Manager
```

## Accessing the Services

After deployment completes, Terraform will output:

- `enhanced_deepseek_ocr_api_endpoint`: API endpoint for direct testing
- `enhanced_open_webui_url`: Web interface URL for interactive testing

## Testing the Enhanced Features

### Via API

```bash
# Get the API endpoint
API_ENDPOINT=$(terraform output -raw enhanced_deepseek_ocr_api_endpoint)

# Test with image + text prompt
curl -X POST $API_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ocr",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}},
        {"type": "text", "text": "Convert this document to markdown."}
      ]
    }]
  }'
```

### Via Open WebUI

1. Access the URL from `enhanced_open_webui_url` output
2. Create an admin account
3. Go to Settings > Connections
4. Add OpenAI API connection with the enhanced API endpoint
5. Upload an image and add a text prompt

## Resource Management

```bash
# List all enhanced instances
terraform output -raw enhanced_list_instances_command | bash

# Manually stop instances
terraform output -raw enhanced_manual_stop_command | bash

# Manually start instances
terraform output -raw enhanced_manual_start_command | bash

# SSH into instances (via SSM Session Manager)
aws ssm start-session --target $(terraform output -raw enhanced_deepseek_ocr_instance_id)
```

## Cleanup

```bash
# Destroy all resources
terraform destroy

# Confirm when prompted
```

## Troubleshooting

### Service Not Ready

```bash
# Check instance status
aws ec2 describe-instances --instance-ids $(terraform output -raw enhanced_deepseek_ocr_instance_id)

# View user-data logs via SSM
aws ssm start-session --target $(terraform output -raw enhanced_deepseek_ocr_instance_id)
# Then: tail -f /var/log/user-data.log

# Check service status
systemctl status deepseek-ocr-server.service
journalctl -u deepseek-ocr-server.service -f
```

### ALB Health Check Failing

```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names enhanced-deepseek-ocr-tg \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
```

## Notes

- Model download takes ~5-10 minutes on first startup
- Rust compilation takes ~5-10 minutes
- Total initialization time: ~15-20 minutes
- Instances automatically stop at 7 PM UTC+7 (12 PM UTC)
- Instances automatically start at 9 AM UTC+7 (2 AM UTC)
