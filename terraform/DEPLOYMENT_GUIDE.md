# Auto Scaling Deployment with ALB

## Architecture Overview

This deployment uses Auto Scaling Groups (ASG) with Application Load Balancers (ALB) for both DeepSeek OCR and Open WebUI services.

### Key Features

1. **Auto Scaling Groups**: Both services run in ASGs with min=0, max=1, desired=1
2. **Scheduled Scaling**: Instances automatically start at 9 AM and stop at 7 PM UTC+7
3. **Persistent DNS**: ALBs provide stable DNS endpoints that don't change
4. **Public Access**: Both services are accessible from the internet via ALB

## Schedule Details

- **Start Time**: 9 AM UTC+7 (2 AM UTC) - Daily
- **Stop Time**: 7 PM UTC+7 (12 PM UTC) - Daily
- **Cron Format**: `0 2 * * *` (start), `0 12 * * *` (stop)

## Architecture Components

### DeepSeek OCR Service
- **ALB**: `deepseek-ocr-alb` (port 8000)
- **ASG**: `deepseek-ocr-asg` (min=0, max=1)
- **Instance Type**: g6.xlarge (GPU)
- **Health Check**: 15 minutes grace period (for model loading)

### Open WebUI Service
- **ALB**: `open-webui-alb` (port 3000)
- **ASG**: `open-webui-asg` (min=0, max=1)
- **Instance Type**: t3.medium
- **Health Check**: 5 minutes grace period

## Security Groups

### ALB Security Groups
- **deepseek-ocr-alb-sg**: Allows inbound on port 8000 from 0.0.0.0/0
- **open-webui-alb-sg**: Allows inbound on port 3000 from 0.0.0.0/0

### Instance Security Groups
- **deepseek-ocr-server-sg**: Allows SSH (22) from anywhere, port 8000 from ALB only
- **open-webui-sg**: Allows SSH (22) from anywhere, port 3000 from ALB only

## Deployment

```bash
# Initialize Terraform
terraform -chdir=terraform init

# Plan the deployment
terraform -chdir=terraform plan

# Apply the configuration
terraform -chdir=terraform apply

# Get outputs (ALB DNS names)
terraform -chdir=terraform output
```

## Access URLs

After deployment, use the ALB DNS names (from outputs):

```bash
# DeepSeek OCR API
http://<deepseek-ocr-alb-dns>:8000

# Open WebUI
http://<open-webui-alb-dns>:3000
```

## Manual Scaling

To manually start/stop instances outside the schedule:

```bash
# Start DeepSeek OCR
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name deepseek-ocr-asg \
  --desired-capacity 1 \
  --region us-west-2

# Stop DeepSeek OCR
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name deepseek-ocr-asg \
  --desired-capacity 0 \
  --region us-west-2

# Start Open WebUI
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name open-webui-asg \
  --desired-capacity 1 \
  --region us-west-2

# Stop Open WebUI
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name open-webui-asg \
  --desired-capacity 0 \
  --region us-west-2
```

## Monitoring

```bash
# Check ASG status
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names deepseek-ocr-asg open-webui-asg \
  --region us-west-2

# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn> \
  --region us-west-2

# List running instances
aws ec2 describe-instances \
  --filters 'Name=tag:Environment,Values=demo' \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
  --output table \
  --region us-west-2
```

## Cost Optimization

- Instances run only 10 hours/day (9 AM - 7 PM UTC+7)
- Saves ~58% on compute costs compared to 24/7 operation
- ALBs run 24/7 but cost is minimal (~$16/month per ALB)

## Notes

1. **First Launch**: DeepSeek OCR takes ~10-15 minutes to download models and become healthy
2. **Persistent DNS**: ALB DNS names remain constant even when instances are stopped
3. **Data Persistence**: Open WebUI data is stored in Docker volumes (lost on instance termination)
4. **SSH Access**: Use instance public IPs when they're running (changes on each start)
