# DeepSeek-OCR Bounding Box API Tests

This directory contains test scripts to verify that the DeepSeek-OCR API correctly returns bounding box coordinates and annotated images.

## Quick Start

Run the comprehensive test:

```bash
./test/run_bbox_test.sh
```

This script will:
1. Automatically get the API endpoint from Terraform
2. Check if the API is reachable
3. Run tests against both `/v1/chat/completions` and `/v1/responses` endpoints
4. Save annotated images to `test/output_*.jpg`

## Manual Testing

### Option 1: Python Script (Recommended)

```bash
python3 test/test_bbox_api.py <API_URL> [image_path]
```

Example:
```bash
python3 test/test_bbox_api.py http://your-alb-dns:8000 test/img/yaki-harasu-neg-18.jpg
```

### Option 2: Bash Script

```bash
bash test/test_bbox_api.sh <API_URL> [image_path]
```

Requires `jq` to be installed.

## Test Image

The test image is located at: `test/img/yaki-harasu-neg-18.jpg`

You can add more test images to the `test/img/` directory.

## Expected Output

The API should return:

1. **Bounding Boxes**: Array of bounding box objects with coordinates
   ```json
   {
     "x1": 100.0,
     "y1": 200.0,
     "x2": 300.0,
     "y2": 400.0,
     "text": "Extracted text"
   }
   ```

2. **Annotated Image**: Base64-encoded JPEG image with bounding boxes drawn on it

## Output Files

After running tests, check these files:
- `test/output_chat_annotated.jpg` - Annotated image from `/v1/chat/completions`
- `test/output_responses_annotated.jpg` - Annotated image from `/v1/responses`
- `test/output_annotated.jpg` - Annotated image from bash script

## Troubleshooting

### API Not Reachable

If the API is not reachable:
1. Check if the EC2 instances are running (they may be stopped by schedule)
2. Verify the security group allows inbound traffic on port 8000
3. Check the ALB health checks

### No Bounding Boxes Returned

**This is expected behavior.** The current DeepSeek-OCR model does not output bounding box coordinates. The API infrastructure is in place, but the model itself only extracts text without spatial information.

See [docs/BOUNDING_BOXES.md](../docs/BOUNDING_BOXES.md) for:
- Detailed explanation
- Workarounds using text detection models
- Example code for two-stage OCR (detection + recognition)

### Open WebUI Not Showing Bounding Boxes

Open WebUI may not display custom fields like `bounding_boxes` and `annotated_image` in its UI. This is a limitation of Open WebUI's interface, not the API itself. The API correctly returns these fields as verified by these test scripts.

To use bounding boxes in your application:
- Call the API directly (not through Open WebUI)
- Parse the `bounding_boxes` array from the response
- Use the `annotated_image` base64 data to display the annotated image

## API Endpoints

### Chat Completions (OpenAI-compatible)

```bash
POST /v1/chat/completions
```

Response includes:
```json
{
  "choices": [{
    "message": {
      "content": "extracted text",
      "bounding_boxes": [...],
      "annotated_image": "base64..."
    }
  }]
}
```

### Responses (Custom format)

```bash
POST /v1/responses
```

Response includes:
```json
{
  "output": [{
    "content": [{
      "text": "extracted text",
      "bounding_boxes": [...],
      "annotated_image": "base64..."
    }]
  }]
}
```
