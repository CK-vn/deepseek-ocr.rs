# Redeployment Guide - Bounding Box Feature

This guide explains how to redeploy the DeepSeek-OCR server with the new default grounding/bounding box features.

## What's New

✅ **Default Grounding Mode**: Bounding boxes are now enabled by default for all OCR requests
✅ **Updated Bbox Extraction**: Supports the official `<|det|>` and `<|ref|>` tag format
✅ **Automatic Prompt Enhancement**: Server automatically adds `<|grounding|>` to prompts
✅ **Backward Compatible**: Legacy formats and explicit "Free OCR" mode still work

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform state in `terraform/` directory
- SSH key file: `terraform/deepseek-ocr-key.pem`
- Running DeepSeek-OCR instance (or ability to start it)

## Deployment Options

### Option 1: Quick Update (Recommended for Testing)

Update the existing running instance without creating a new one:

```bash
./scripts/update_instance.sh
```

This will:
1. Find your running DeepSeek-OCR instance
2. SSH into it
3. Pull the latest code from GitHub
4. Rebuild the server with CUDA support
5. Restart the service

**Time**: ~5-10 minutes (depending on build time)
**Downtime**: ~30 seconds during service restart

### Option 2: Full Redeployment

For production deployments, use instance refresh to create a new instance:

```bash
./scripts/redeploy.sh
```

This interactive script will:
1. Commit your changes to git
2. Push to remote repository (optional)
3. Find your current instance
4. Offer deployment methods:
   - **Instance Refresh**: Gradual replacement with health checks
   - **Terminate Instance**: Immediate replacement
   - **Manual Update**: SSH-based update

**Time**: ~10-15 minutes
**Downtime**: Minimal (with instance refresh) or ~3-5 minutes (with terminate)

### Option 3: Manual Update

If you prefer manual control:

1. **SSH into the instance:**
   ```bash
   cd terraform
   INSTANCE_IP=$(aws ec2 describe-instances \
       --filters "Name=tag:Name,Values=deepseek-ocr-instance" \
                 "Name=instance-state-name,Values=running" \
       --query 'Reservations[0].Instances[0].PublicIpAddress' \
       --output text)
   
   ssh -i deepseek-ocr-key.pem ubuntu@$INSTANCE_IP
   ```

2. **Update the code:**
   ```bash
   cd deepseek-ocr.rs
   git pull origin master
   ```

3. **Rebuild the server:**
   ```bash
   source ~/.cargo/env
   cargo build --release -p deepseek-ocr-server --features cuda
   ```

4. **Restart the service:**
   ```bash
   sudo systemctl restart deepseek-ocr-server
   sudo systemctl status deepseek-ocr-server
   ```

## Verification

After deployment, verify the new features are working:

### 1. Check Service Health

```bash
cd terraform
API_ENDPOINT=$(terraform output -raw deepseek_ocr_api_endpoint)
curl $API_ENDPOINT/v1/health
```

Expected output: `ok`

### 2. Test Bounding Boxes

```bash
cd ..
./test/run_bbox_test.sh
```

This will:
- Send a test image to the API
- Verify bounding boxes are returned
- Save annotated images to `test/output_*.jpg`

### 3. Check Service Logs

SSH into the instance and check logs:

```bash
ssh -i terraform/deepseek-ocr-key.pem ubuntu@$INSTANCE_IP
sudo journalctl -u deepseek-ocr-server -f
```

Look for successful startup messages and no errors.

## Troubleshooting

### Instance Not Running

If the instance is stopped by schedule:

```bash
cd terraform
ASG_NAME=$(terraform output -raw deepseek_ocr_asg_name)
aws autoscaling set-desired-capacity \
    --auto-scaling-group-name $ASG_NAME \
    --desired-capacity 1
```

Wait 3-5 minutes for the instance to start.

### Build Failures

If the build fails on the instance:

1. Check Rust version: `rustc --version` (should be 1.70+)
2. Check CUDA: `nvidia-smi` (should show GPU)
3. Check disk space: `df -h` (should have >10GB free)
4. Check logs: `tail -100 /var/log/user-data.log`

### Service Won't Start

Check the service logs:

```bash
sudo systemctl status deepseek-ocr-server
sudo journalctl -u deepseek-ocr-server -n 100
```

Common issues:
- Model files not downloaded (wait for first run)
- Port 8000 already in use
- CUDA initialization failed

### Bounding Boxes Not Returned

If bounding boxes are still not returned after update:

1. Verify the code was actually updated:
   ```bash
   cd /home/ubuntu/deepseek-ocr.rs
   git log -1
   ```

2. Check if the binary was rebuilt:
   ```bash
   ls -lh target/release/deepseek-ocr-server
   ```

3. Verify the service is using the new binary:
   ```bash
   sudo systemctl status deepseek-ocr-server
   ```

4. Test with explicit grounding prompt:
   ```bash
   # Use the test script with verbose output
   python3 test/test_bbox_api.py $API_ENDPOINT test/img/yaki-harasu-neg-18.jpg
   ```

## Rollback

If you need to rollback to the previous version:

### Quick Rollback (SSH Method)

```bash
ssh -i terraform/deepseek-ocr-key.pem ubuntu@$INSTANCE_IP
cd deepseek-ocr.rs
git log  # Find the previous commit hash
git checkout <previous-commit-hash>
source ~/.cargo/env
cargo build --release -p deepseek-ocr-server --features cuda
sudo systemctl restart deepseek-ocr-server
```

### Full Rollback (Terraform)

1. Revert your git changes locally
2. Run the redeployment script again

## Post-Deployment

After successful deployment:

1. **Update Open WebUI** (if using):
   - No configuration needed! Bounding boxes work automatically
   - Optionally set system prompt to customize behavior

2. **Update Documentation**:
   - Share the new API capabilities with your team
   - Update any integration code to use bounding boxes

3. **Monitor Performance**:
   - Check response times (grounding mode may be slightly slower)
   - Monitor GPU memory usage
   - Check for any errors in logs

## Support

For issues or questions:
- Check logs: `/var/log/deepseek-ocr-server.log`
- Review documentation: `docs/BOUNDING_BOXES.md`
- Test locally before deploying to production

## Next Steps

After successful deployment:
- Test with your own images
- Integrate bounding boxes into your application
- Explore different grounding modes (see `docs/BOUNDING_BOXES.md`)
