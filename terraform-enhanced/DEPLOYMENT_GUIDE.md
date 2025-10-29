# DeepSeek OCR Deployment Guide

This guide covers deploying and managing the DeepSeek OCR infrastructure with automatic startup and scheduling.

## Quick Start

### Initial Deployment

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

### Wait for Services to be Ready

After deployment, wait for services to complete initialization:

```bash
./verify_services_ready.sh
```

This will monitor both services and notify you when they're fully operational (typically 15-20 minutes for first boot).

## Architecture

### Components

1. **DeepSeek OCR Server** (g6.xlarge GPU instance)
   - Rust-based OCR service with CUDA acceleration
   - Exposed via Application Load Balancer on port 8000
   - Persistent EBS volume (50GB)

2. **Open WebUI** (t3.medium instance)
   - Docker-based web interface
   - Exposed via Application Load Balancer on port 3000
   - Persistent EBS volume (30GB)

3. **Lambda Scheduler**
   - Automatically stops instances at 7 PM UTC+7 (12 PM UTC)
   - Automatically starts instances at 9 AM UTC+7 (2 AM UTC)
   - Preserves all data on EBS volumes

4. **Application Load Balancers**
   - Provide persistent DNS names
   - Health checks ensure traffic only goes to healthy instances
   - Automatic failover if instance becomes unhealthy

## Startup Times

### First Boot (Fresh Instance)
- **Total Time**: ~15-20 minutes
- CUDA driver compilation: ~5 minutes
- Rust code compilation: ~5 minutes
- Model download and loading: ~5 minutes

### Subsequent Boots (With AMI Snapshots)
- **Total Time**: ~5 minutes
- All dependencies pre-installed
- Binary pre-compiled
- Model pre-cached

## Improving Startup Time

After your first successful deployment, create AMI snapshots:

```bash
./create_ami_snapshots.sh
```

This will:
1. Create AMI snapshots of both running instances
2. Wait for AMIs to be available
3. Provide instructions to update terraform configuration

Future deployments using these AMIs will start in ~5 minutes instead of ~15-20 minutes.

## Service Management

### Check Service Status

```bash
# Quick status check
./check_deepseek_status.sh

# Detailed verification
./verify_services_ready.sh
```

### Manual Instance Control

Stop instances immediately:
```bash
aws lambda invoke --function-name ec2-instance-scheduler \
  --payload '{"action":"stop"}' /tmp/response.json --region us-west-2
```

Start instances immediately:
```bash
aws lambda invoke --function-name ec2-instance-scheduler \
  --payload '{"action":"start"}' /tmp/response.json --region us-west-2
```

### View Instance States

```bash
aws ec2 describe-instances \
  --filters 'Name=tag:Environment,Values=demo' \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name,LaunchTime]' \
  --output table --region us-west-2
```

## Automatic Scheduling

Instances automatically:
- **Stop at 7 PM UTC+7** (12 PM UTC) daily
- **Start at 9 AM UTC+7** (2 AM UTC) daily

This saves costs while preserving all data on EBS volumes.

### Modify Schedule

Edit `terraform/main.tf` and update the cron expressions:

```hcl
# Stop schedule (currently 12 PM UTC = 7 PM UTC+7)
resource "aws_cloudwatch_event_rule" "stop_instances" {
  schedule_expression = "cron(0 12 * * ? *)"
}

# Start schedule (currently 2 AM UTC = 9 AM UTC+7)
resource "aws_cloudwatch_event_rule" "start_instances" {
  schedule_expression = "cron(0 2 * * ? *)"
}
```

Then apply changes:
```bash
terraform apply
```

## Health Checks

### ALB Health Checks

Both services have health checks configured:

**DeepSeek OCR**:
- Path: `/v1/health`
- Interval: 30 seconds
- Healthy threshold: 2 consecutive successes
- Unhealthy threshold: 10 consecutive failures

**Open WebUI**:
- Path: `/`
- Interval: 30 seconds
- Healthy threshold: 2 consecutive successes
- Unhealthy threshold: 10 consecutive failures

### Service Logs

**DeepSeek OCR logs**:
```bash
aws ssm start-session --target <instance-id> --region us-west-2
tail -f /var/log/deepseek-ocr-server.log
```

**Open WebUI logs**:
```bash
aws ssm start-session --target <instance-id> --region us-west-2
docker logs -f open-webui
```

## Troubleshooting

### Service Not Starting

1. Check instance state:
   ```bash
   aws ec2 describe-instances --instance-ids <instance-id> --region us-west-2
   ```

2. Check user-data logs:
   ```bash
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["tail -100 /var/log/user-data.log"]' \
     --region us-west-2
   ```

3. Check service status:
   ```bash
   # For DeepSeek OCR
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["systemctl status deepseek-ocr-server"]' \
     --region us-west-2
   
   # For Open WebUI
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["docker ps -a","docker logs open-webui --tail 50"]' \
     --region us-west-2
   ```

### 502 Bad Gateway

This is normal during startup. The ALB returns 502 while the backend service is initializing. Wait for the service to complete startup (use `verify_services_ready.sh`).

### High Costs

If costs are too high:
1. Reduce instance uptime by adjusting the schedule
2. Use smaller instance types (edit `terraform/variables.tf`)
3. Stop instances when not in use (manual control commands above)

## Cleanup

To destroy all resources:

```bash
cd terraform
terraform destroy -auto-approve
```

**Warning**: This will delete all instances and data. EBS volumes are set to not delete automatically, so you may need to manually delete them if desired.

## Configuration Files

- `main.tf` - Main infrastructure definition
- `variables.tf` - Configurable parameters
- `outputs.tf` - Deployment outputs (URLs, IDs, etc.)
- `user-data.sh` - DeepSeek OCR initialization script
- `open-webui-user-data.sh` - Open WebUI initialization script
- `lambda_scheduler.py` - Instance scheduler Lambda function

## Support

For issues with:
- **Infrastructure**: Check terraform logs and AWS console
- **DeepSeek OCR**: Check service logs and GitHub issues
- **Open WebUI**: Check Docker logs and Open WebUI documentation

## Best Practices

1. **Always use the verification script** after deployment to ensure services are ready
2. **Create AMI snapshots** after first successful boot for faster future deployments
3. **Monitor costs** regularly in AWS Cost Explorer
4. **Keep EBS snapshots** of important data before major changes
5. **Test the scheduler** to ensure it works as expected for your timezone
6. **Use SSM Session Manager** instead of SSH for secure access
7. **Review security groups** periodically to ensure they're not too permissive

## Next Steps

After deployment:
1. Run `./verify_services_ready.sh` to wait for services
2. Access Open WebUI and create an admin account
3. Configure Open WebUI to connect to DeepSeek OCR API
4. Test OCR functionality with sample images
5. Create AMI snapshots for faster future deployments
6. Set up monitoring and alerts if needed
