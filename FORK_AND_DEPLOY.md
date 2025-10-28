# Fork and Deploy Guide

Quick guide to fork the repository and deploy your changes.

## Prerequisites

1. **GitHub Account**: You need access to create the fork at `CK-vn/deepseek-ocr.rs`
2. **GitHub Fork**: Create a fork of `TimmyOVO/deepseek-ocr.rs` at https://github.com/CK-vn/deepseek-ocr.rs
3. **AWS Access**: Configured AWS CLI with permissions to manage EC2 instances
4. **SSH Key**: The `terraform/deepseek-ocr-key.pem` file must exist

## Step-by-Step Process

### Step 1: Create GitHub Fork

1. Go to https://github.com/TimmyOVO/deepseek-ocr.rs
2. Click "Fork" button
3. Set owner to `CK-vn`
4. Repository name: `deepseek-ocr.rs`
5. Click "Create fork"

### Step 2: Setup Local Fork

Run the setup script:

```bash
./scripts/setup_fork.sh
```

This will:
- Add your fork as a remote named `fork`
- Add original repo as `upstream`
- Create a feature branch: `feature/default-grounding-bbox`
- Commit all your changes
- Push to your fork

### Step 3: Deploy Changes

Run the deployment script:

```bash
./scripts/deploy_changes.sh
```

This interactive script will:
1. Verify fork is setup correctly
2. Ensure changes are pushed
3. Update Terraform to use your fork
4. Offer deployment methods:
   - **Quick Update**: Update existing instance (5-10 min)
   - **New Instance**: Terminate and recreate (10-15 min)
   - **Instance Refresh**: Production-grade deployment (15-20 min)

### Step 4: Verify Deployment

After deployment completes:

```bash
# Check service health
cd terraform
./check_services.sh

# Test bounding boxes
cd ..
./test/run_bbox_test.sh
```

## Manual Process (Alternative)

If you prefer manual control:

### 1. Setup Fork Manually

```bash
# Add fork remote
git remote add fork https://github.com/CK-vn/deepseek-ocr.rs.git
git remote add upstream https://github.com/TimmyOVO/deepseek-ocr.rs.git

# Create feature branch
git checkout -b feature/default-grounding-bbox

# Commit changes
git add -A
git commit -m "feat: Add default grounding mode for bounding boxes"

# Push to fork
git push -u fork feature/default-grounding-bbox
```

### 2. Update Terraform

Edit `terraform/user-data.sh`:

```bash
# Change this line:
git clone https://github.com/TimmyOVO/deepseek-ocr.rs.git

# To:
git clone -b feature/default-grounding-bbox https://github.com/CK-vn/deepseek-ocr.rs.git
```

Also update the git pull command:

```bash
# Change:
git pull

# To:
git pull origin feature/default-grounding-bbox
```

### 3. Deploy

Choose one method:

**A. Update Existing Instance:**
```bash
cd terraform
INSTANCE_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

ssh -i deepseek-ocr-key.pem ubuntu@$INSTANCE_IP

# On the instance:
cd deepseek-ocr.rs
git remote set-url origin https://github.com/CK-vn/deepseek-ocr.rs.git
git fetch origin
git checkout feature/default-grounding-bbox
git pull origin feature/default-grounding-bbox
source ~/.cargo/env
cargo build --release -p deepseek-ocr-server --features cuda
sudo systemctl restart deepseek-ocr-server
```

**B. Create New Instance:**
```bash
cd terraform
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)

aws ec2 terminate-instances --instance-ids $INSTANCE_ID
# Wait for Auto Scaling Group to launch new instance
```

## Troubleshooting

### Fork Remote Not Found

```bash
git remote add fork https://github.com/CK-vn/deepseek-ocr.rs.git
```

### Permission Denied (GitHub)

Make sure you have:
1. Created the fork on GitHub
2. Have push access to `CK-vn/deepseek-ocr.rs`
3. GitHub credentials configured (SSH key or token)

### Instance Not Found

The instance may be stopped by schedule:

```bash
cd terraform
ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name)
aws autoscaling set-desired-capacity \
    --auto-scaling-group-name $ASG_NAME \
    --desired-capacity 1
```

### Build Fails on Instance

Check logs:
```bash
ssh -i terraform/deepseek-ocr-key.pem ubuntu@$INSTANCE_IP
tail -100 /var/log/user-data.log
sudo journalctl -u deepseek-ocr-server -n 100
```

## Verification

After deployment:

1. **Check API Health:**
   ```bash
   curl http://your-alb-dns:8000/v1/health
   ```

2. **Test Bounding Boxes:**
   ```bash
   python3 test/test_bbox_api.py http://your-alb-dns:8000
   ```

3. **Check Logs:**
   ```bash
   ssh -i terraform/deepseek-ocr-key.pem ubuntu@$INSTANCE_IP
   sudo journalctl -u deepseek-ocr-server -f
   ```

## Next Steps

After successful deployment:

1. **Test with your images**: Upload test images and verify bounding boxes
2. **Update Open WebUI**: No configuration needed, it works automatically
3. **Monitor performance**: Check response times and GPU usage
4. **Create PR** (optional): If you want to contribute back to upstream

## Support

- Documentation: `docs/BOUNDING_BOXES.md`
- Deployment Guide: `REDEPLOYMENT_GUIDE.md`
- Test Scripts: `test/README.md`
