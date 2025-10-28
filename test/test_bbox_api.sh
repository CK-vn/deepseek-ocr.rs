#!/bin/bash
# Test script to verify DeepSeek-OCR API returns bounding boxes

set -e

API_URL="${1:-}"
IMAGE_PATH="${2:-test/img/yaki-harasu-neg-18.jpg}"

if [ -z "$API_URL" ]; then
    echo "Usage: $0 <API_URL> [image_path]"
    echo "Example: $0 http://your-alb-dns:8000 test/img/yaki-harasu-neg-18.jpg"
    exit 1
fi

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: Image file not found: $IMAGE_PATH"
    exit 1
fi

echo "=========================================="
echo "Testing DeepSeek-OCR Bounding Box API"
echo "=========================================="
echo "API URL: $API_URL"
echo "Image: $IMAGE_PATH"
echo ""

# Encode image to base64
echo "Encoding image to base64..."
IMAGE_BASE64=$(base64 -w 0 "$IMAGE_PATH")
IMAGE_DATA_URL="data:image/jpeg;base64,$IMAGE_BASE64"

# Test /v1/chat/completions endpoint
echo ""
echo "=========================================="
echo "Testing /v1/chat/completions"
echo "=========================================="

RESPONSE=$(curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "model": "deepseek-ocr",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "Extract all text from this image with bounding boxes."
        },
        {
          "type": "image_url",
          "image_url": {
            "url": "$IMAGE_DATA_URL"
          }
        }
      ]
    }
  ],
  "max_tokens": 512
}
EOF
)

echo "Response:"
echo "$RESPONSE" | jq '.'

# Check for bounding boxes
BBOX_COUNT=$(echo "$RESPONSE" | jq '.choices[0].message.bounding_boxes | length' 2>/dev/null || echo "0")
HAS_ANNOTATED=$(echo "$RESPONSE" | jq '.choices[0].message.annotated_image != null' 2>/dev/null || echo "false")

echo ""
echo "=========================================="
echo "RESULTS:"
echo "=========================================="
echo "✓ Number of bounding boxes: $BBOX_COUNT"
echo "✓ Has annotated image: $HAS_ANNOTATED"

if [ "$BBOX_COUNT" != "0" ] && [ "$BBOX_COUNT" != "null" ]; then
    echo ""
    echo "First bounding box:"
    echo "$RESPONSE" | jq '.choices[0].message.bounding_boxes[0]'
fi

if [ "$HAS_ANNOTATED" = "true" ]; then
    echo ""
    echo "Saving annotated image..."
    echo "$RESPONSE" | jq -r '.choices[0].message.annotated_image' | base64 -d > test/output_annotated.jpg
    echo "✓ Saved to: test/output_annotated.jpg"
fi

echo ""
echo "=========================================="
echo "Testing complete!"
echo "=========================================="
