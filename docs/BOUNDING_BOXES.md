# Bounding Box Support in DeepSeek-OCR

## Current Status

✅ **The DeepSeek-OCR model DOES support bounding box output** when using the grounding feature!

✅ **Grounding is ENABLED BY DEFAULT** - No configuration needed!

### What's Implemented

✅ **API Response Fields**: Both `/v1/chat/completions` and `/v1/responses` endpoints include:
- `bounding_boxes`: Array of bounding box objects with coordinates
- `annotated_image`: Base64-encoded image with boxes drawn

✅ **Extraction Logic**: The server parses bounding boxes from model output in the format:
```
<|ref|>text content<|/ref|><|det|>[[x1, y1, x2, y2]]<|/det|>
```

✅ **Visualization**: Automatic generation of annotated images with colored bounding boxes

✅ **Auto-Grounding**: The server automatically enables grounding mode for all requests unless explicitly disabled

See [DEFAULT_GROUNDING.md](DEFAULT_GROUNDING.md) for details on the automatic grounding behavior.

## Quick Start

**Bounding boxes are enabled by default!** Just send a normal OCR request:

```json
{
  "model": "deepseek-ocr",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Extract all text from this image."},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
    ]
  }]
}
```

The server automatically adds `<|grounding|>` to enable bounding boxes.

## Advanced Usage

### Method 1: Explicit Grounding Prompt

You can explicitly include `<|grounding|>` in your prompt:

```json
{
  "model": "deepseek-ocr",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "text",
        "text": "<image>\n<|grounding|>Convert the document to markdown."
      },
      {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,..."}
      }
    ]
  }],
  "max_tokens": 1024
}
```

### Method 2: Locate Specific Objects

Use the reference tag to locate specific text or objects:

```json
{
  "model": "deepseek-ocr",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "text",
        "text": "<image>\nLocate <|ref|>the teacher<|/ref|> in the image."
      },
      {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,..."}
      }
    ]
  }]
}
```

### Method 3: Disable Bounding Boxes (Free OCR)

To disable bounding boxes and get text-only output, use `Free OCR.`:

```json
{
  "model": "deepseek-ocr",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "text",
        "text": "<image>\nFree OCR."
      },
      {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,..."}
      }
    ]
  }]
}
```

## Model Output Format

When grounding is enabled, the model outputs bounding boxes in this format:

```
<|det|>[[280, 15, 696, 997]]<|/det|>
```

Or with reference text:

```
<|ref|>Product Name<|/ref|><|det|>[[100, 50, 400, 80]]<|/det|>
```

Coordinates are normalized to a 1000x1000 space and need to be scaled to your image dimensions.

## API Response Format

### Chat Completions Response
```json
{
  "choices": [{
    "message": {
      "content": "extracted text (with bbox tags stripped)",
      "bounding_boxes": [
        {
          "x1": 280.0,
          "y1": 15.0,
          "x2": 696.0,
          "y2": 997.0,
          "text": "Product Name"
        }
      ],
      "annotated_image": "base64_encoded_jpeg..."
    }
  }]
}
```

### Bounding Box Object
```json
{
  "x1": 100.0,    // Top-left x (normalized 0-1000)
  "y1": 200.0,    // Top-left y (normalized 0-1000)
  "x2": 300.0,    // Bottom-right x (normalized 0-1000)
  "y2": 400.0,    // Bottom-right y (normalized 0-1000)
  "text": "content"  // Optional: referenced text
}
```

## Testing

Run the test script to verify bounding box functionality:

```bash
# Automatic test with Terraform endpoint
./test/run_bbox_test.sh

# Manual test
python3 test/test_bbox_api.py <API_URL> test/img/yaki-harasu-neg-18.jpg
```

## Open WebUI Configuration

**No configuration needed!** Grounding mode is enabled by default.

Simply use Open WebUI normally, and bounding boxes will be included in the API responses automatically.

### Optional: Customize System Prompt

If you want to customize the behavior:

1. Go to Open WebUI settings
2. Navigate to the model configuration
3. Set the system prompt to one of:

**For explicit grounding (default behavior):**
```
<image>
<|grounding|>Convert the document to markdown.
```

**For free OCR without bounding boxes:**
```
<image>
Free OCR.
```

**Note**: Open WebUI may not display the `bounding_boxes` and `annotated_image` fields in its UI, but they are included in the API response. For full access to these features, call the API directly.

## Supported Tasks

The DeepSeek-OCR model supports several task types:

1. **Free OCR**: `<image>\nFree OCR.`
   - Basic text extraction without bounding boxes

2. **Markdown Conversion with Grounding**: `<image>\n<|grounding|>Convert the document to markdown.`
   - Converts document to markdown with bounding boxes

3. **Figure Parsing**: `<image>\nParse the figure.`
   - Extracts structured data from charts and figures

4. **Object Localization**: `<image>\nLocate <|ref|>text<|/ref|> in the image.`
   - Finds specific objects/text and returns their bounding boxes

## Coordinate System

- Coordinates are normalized to a **1000x1000** space
- To convert to pixel coordinates:
  ```python
  x_pixel = (x_normalized / 1000.0) * image_width
  y_pixel = (y_normalized / 1000.0) * image_height
  ```

## Examples

See `examples/bbox_with_easyocr.py` for a complete example of using bounding boxes in a Python application.

## Reference

Based on the official DeepSeek-OCR demo:
https://huggingface.co/spaces/khang119966/DeepSeek-OCR-DEMO
