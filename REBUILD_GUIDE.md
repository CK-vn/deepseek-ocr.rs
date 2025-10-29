# Rebuild and Redeploy Guide

## What Was Fixed

Fixed the "prompt/image embedding mismatch: 2 slots vs 1 embeddings" error that occurred when users uploaded an image and added text in a single turn in Open WebUI.

### Root Cause
The prompt formatting logic was allowing multiple `<image>` tags to appear in the final prompt (from user text or system messages), but only one actual image was provided. This caused a mismatch between the number of image slots in the prompt and the number of image embeddings.

### Solution
Modified `convert_messages()` function in `crates/server/src/main.rs` to:
1. Remove any `<image>` tags from the user's text body
2. Add exactly one `<image>` tag per actual image at the beginning of the prompt
3. Ensure the number of `<image>` tags always matches the number of images provided

## How to Rebuild and Redeploy

### Option 1: Rebuild on EC2 Instance (Recommended)

```bash
# 1. SSH into the enhanced DeepSeek OCR instance
aws ssm start-session --target $(cd terraform-enhanced && terraform output -raw enhanced_deepseek_ocr_instance_id)

# 2. Navigate to the repository
cd /home/ubuntu/deepseek-ocr.rs

# 3. Pull the latest changes from the feature branch
sudo -u ubuntu git fetch origin
sudo -u ubuntu git pull origin feature/multimodal-ocr-with-bbox

# 4. Rebuild the server
sudo -u ubuntu bash -c 'source $HOME/.cargo/env && cargo build --release -p deepseek-ocr-server --features cuda'

# 5. Restart the service
sudo systemctl restart deepseek-ocr-server.service

# 6. Check service status
sudo systemctl status deepseek-ocr-server.service

# 7. Monitor logs
sudo journalctl -u deepseek-ocr-server.service -f
```

### Option 2: Redeploy Infrastructure (Clean Slate)

```bash
# 1. Destroy existing enhanced deployment
cd terraform-enhanced
terraform destroy

# 2. Commit and push your changes to the feature branch
git add crates/server/src/main.rs
git commit -m "Fix image slot mismatch error in prompt formatting"
git push origin feature/multimodal-ocr-with-bbox

# 3. Redeploy infrastructure
terraform apply

# 4. Wait for initialization (~15-20 minutes)
# Monitor via CloudWatch Logs or SSM Session Manager
```

## Testing the Fix

### Test Case: Image + Text in Single Turn

```bash
# Get the API endpoint
cd terraform-enhanced
API_ENDPOINT=$(terraform output -raw enhanced_deepseek_ocr_api_endpoint)

# Test with a sample image and text
curl -X POST $API_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ocr",
    "messages": [{
      "role": "user",
      "content": [
        {
          "type": "image_url",
          "image_url": {
            "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
          }
        },
        {
          "type": "text",
          "text": "What do you see in this image?"
        }
      ]
    }],
    "max_tokens": 512
  }'
```

### Expected Result
- No "prompt/image embedding mismatch" error
- Response includes the OCR text with markup tags
- Bounding boxes are extracted (if present in image)
- Annotated image is included (if bounding boxes exist)

### Test via Open WebUI

1. Access Open WebUI: `terraform output -raw enhanced_open_webui_url`
2. Upload an image
3. Type a message like "Convert this to markdown"
4. Submit the request
5. Verify no errors occur and response is generated

## Verification Checklist

- [ ] Code compiles without errors
- [ ] Service starts successfully
- [ ] Health endpoint responds: `curl http://localhost:8000/v1/health`
- [ ] Image + text request works without mismatch error
- [ ] Image-only request still works (backward compatibility)
- [ ] Bounding boxes are extracted correctly
- [ ] Annotated images are generated when boxes exist
- [ ] Open WebUI can successfully send requests

## Rollback Plan

If issues occur:

```bash
# Option 1: Revert to previous commit
cd /home/ubuntu/deepseek-ocr.rs
sudo -u ubuntu git reset --hard HEAD~1
sudo -u ubuntu bash -c 'source $HOME/.cargo/env && cargo build --release -p deepseek-ocr-server --features cuda'
sudo systemctl restart deepseek-ocr-server.service

# Option 2: Destroy enhanced deployment
cd terraform-enhanced
terraform destroy
```
