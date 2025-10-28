#!/bin/bash
# Get the DeepSeek-OCR API endpoint from Terraform outputs

cd terraform 2>/dev/null || cd ../terraform 2>/dev/null || true

if [ ! -f terraform.tfstate ]; then
    echo "Error: terraform.tfstate not found"
    echo "Please run this from the project root or terraform directory"
    exit 1
fi

API_ENDPOINT=$(terraform output -raw deepseek_ocr_api_endpoint 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
    echo "Error: Could not get API endpoint from Terraform"
    exit 1
fi

echo "$API_ENDPOINT"
