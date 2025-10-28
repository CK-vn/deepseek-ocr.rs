#!/usr/bin/env python3
"""
Test script to verify DeepSeek-OCR API returns bounding boxes and annotated images.
"""

import base64
import json
import sys
import requests
from pathlib import Path

def encode_image_to_base64(image_path):
    """Encode image file to base64 data URL."""
    with open(image_path, 'rb') as f:
        image_data = f.read()
    b64_data = base64.b64encode(image_data).decode('utf-8')
    # Detect image format from extension
    ext = Path(image_path).suffix.lower()
    mime_type = {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.gif': 'image/gif',
        '.webp': 'image/webp'
    }.get(ext, 'image/jpeg')
    return f"data:{mime_type};base64,{b64_data}"

def test_chat_completions(api_url, image_path):
    """Test /v1/chat/completions endpoint."""
    print(f"\n{'='*60}")
    print("Testing /v1/chat/completions endpoint")
    print(f"{'='*60}")
    
    image_url = encode_image_to_base64(image_path)
    
    payload = {
        "model": "deepseek-ocr",
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Extract all text from this image."
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": image_url}
                    }
                ]
            }
        ],
        "max_tokens": 1024
    }
    
    try:
        response = requests.post(
            f"{api_url}/v1/chat/completions",
            json=payload,
            timeout=120
        )
        response.raise_for_status()
        result = response.json()
        
        print(f"\nStatus: {response.status_code}")
        print(f"\nFull Response:")
        print(json.dumps(result, indent=2))
        
        # Check for bounding boxes
        if 'choices' in result and len(result['choices']) > 0:
            message = result['choices'][0].get('message', {})
            bboxes = message.get('bounding_boxes')
            annotated = message.get('annotated_image')
            
            print(f"\n{'='*60}")
            print("RESULTS:")
            print(f"{'='*60}")
            print(f"✓ Bounding boxes present: {bboxes is not None}")
            if bboxes:
                print(f"✓ Number of bounding boxes: {len(bboxes)}")
                print(f"\nFirst few bounding boxes:")
                for i, bbox in enumerate(bboxes[:3]):
                    print(f"  Box {i+1}: {bbox}")
            
            print(f"\n✓ Annotated image present: {annotated is not None}")
            if annotated:
                print(f"✓ Annotated image size: {len(annotated)} characters (base64)")
                # Save annotated image
                save_annotated_image(annotated, "test/output_chat_annotated.jpg")
        
        return result
        
    except requests.exceptions.RequestException as e:
        print(f"✗ Error: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"Response: {e.response.text}")
        return None

def test_responses(api_url, image_path):
    """Test /v1/responses endpoint."""
    print(f"\n{'='*60}")
    print("Testing /v1/responses endpoint")
    print(f"{'='*60}")
    
    image_url = encode_image_to_base64(image_path)
    
    payload = {
        "model": "deepseek-ocr",
        "input": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Extract all text from this image."
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": image_url}
                    }
                ]
            }
        ],
        "max_tokens": 1024
    }
    
    try:
        response = requests.post(
            f"{api_url}/v1/responses",
            json=payload,
            timeout=120
        )
        response.raise_for_status()
        result = response.json()
        
        print(f"\nStatus: {response.status_code}")
        print(f"\nFull Response:")
        print(json.dumps(result, indent=2))
        
        # Check for bounding boxes
        if 'output' in result and len(result['output']) > 0:
            content = result['output'][0].get('content', [])
            if content:
                bboxes = content[0].get('bounding_boxes')
                annotated = content[0].get('annotated_image')
                
                print(f"\n{'='*60}")
                print("RESULTS:")
                print(f"{'='*60}")
                print(f"✓ Bounding boxes present: {bboxes is not None}")
                if bboxes:
                    print(f"✓ Number of bounding boxes: {len(bboxes)}")
                    print(f"\nFirst few bounding boxes:")
                    for i, bbox in enumerate(bboxes[:3]):
                        print(f"  Box {i+1}: {bbox}")
                
                print(f"\n✓ Annotated image present: {annotated is not None}")
                if annotated:
                    print(f"✓ Annotated image size: {len(annotated)} characters (base64)")
                    # Save annotated image
                    save_annotated_image(annotated, "test/output_responses_annotated.jpg")
        
        return result
        
    except requests.exceptions.RequestException as e:
        print(f"✗ Error: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"Response: {e.response.text}")
        return None

def save_annotated_image(base64_data, output_path):
    """Save base64 encoded image to file."""
    try:
        image_bytes = base64.b64decode(base64_data)
        with open(output_path, 'wb') as f:
            f.write(image_bytes)
        print(f"✓ Saved annotated image to: {output_path}")
    except Exception as e:
        print(f"✗ Failed to save annotated image: {e}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python test_bbox_api.py <API_URL> [image_path]")
        print("Example: python test_bbox_api.py http://your-alb-dns:8000 test/img/yaki-harasu-neg-18.jpg")
        sys.exit(1)
    
    api_url = sys.argv[1].rstrip('/')
    image_path = sys.argv[2] if len(sys.argv) > 2 else "test/img/yaki-harasu-neg-18.jpg"
    
    if not Path(image_path).exists():
        print(f"Error: Image file not found: {image_path}")
        sys.exit(1)
    
    print(f"API URL: {api_url}")
    print(f"Image: {image_path}")
    
    # Test both endpoints
    test_chat_completions(api_url, image_path)
    print("\n" + "="*60 + "\n")
    test_responses(api_url, image_path)
    
    print(f"\n{'='*60}")
    print("Testing complete!")
    print(f"{'='*60}")

if __name__ == "__main__":
    main()
