#!/bin/bash
# Comprehensive test runner for bounding box API verification

set -e

echo "=========================================="
echo "DeepSeek-OCR Bounding Box Test Runner"
echo "=========================================="
echo ""

# Get API endpoint
echo "Getting API endpoint from Terraform..."
cd terraform 2>/dev/null || true

API_ENDPOINT=$(terraform output -raw deepseek_ocr_api_endpoint 2>/dev/null || echo "")

if [ -z "$API_ENDPOINT" ]; then
    echo "⚠ Could not get API endpoint from Terraform"
    echo "Please provide the API endpoint manually:"
    read -p "API URL: " API_ENDPOINT
fi

cd - > /dev/null 2>&1 || true

echo "✓ API Endpoint: $API_ENDPOINT"
echo ""

# Check if API is reachable
echo "Checking API health..."
if curl -s -f "$API_ENDPOINT/v1/health" > /dev/null 2>&1; then
    echo "✓ API is reachable"
else
    echo "✗ API is not reachable at $API_ENDPOINT"
    echo "Please check if the service is running"
    exit 1
fi

echo ""
echo "=========================================="
echo "Running Tests"
echo "=========================================="
echo ""

# Check which test method to use
if command -v python3 &> /dev/null; then
    echo "Using Python test script..."
    python3 test/test_bbox_api.py "$API_ENDPOINT" test/img/yaki-harasu-neg-18.jpg
elif command -v jq &> /dev/null; then
    echo "Using bash test script..."
    bash test/test_bbox_api.sh "$API_ENDPOINT" test/img/yaki-harasu-neg-18.jpg
else
    echo "⚠ Neither python3 nor jq found. Installing jq..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y jq
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq
    elif command -v brew &> /dev/null; then
        brew install jq
    else
        echo "✗ Could not install jq. Please install python3 or jq manually."
        exit 1
    fi
    bash test/test_bbox_api.sh "$API_ENDPOINT" test/img/yaki-harasu-neg-18.jpg
fi

echo ""
echo "=========================================="
echo "Test Complete!"
echo "=========================================="
echo ""
echo "Check the test/output_*.jpg files for annotated images"
