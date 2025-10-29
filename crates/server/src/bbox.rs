/// Bounding box extraction and drawing utilities for DeepSeek-OCR output.
///
/// The model outputs bounding boxes in the format: <box>[[x1,y1],[x2,y2]]</box>
/// or <ref>text</ref><box>[[x1,y1],[x2,y2]]</box>

use anyhow::{Result, anyhow};
use image::{DynamicImage, Rgba, RgbaImage};
use imageproc::drawing::{draw_hollow_rect_mut, draw_text_mut};
use imageproc::rect::Rect;
use regex::Regex;
use ab_glyph::{FontRef, PxScale};
use serde::{Deserialize, Serialize};

/// A bounding box with optional reference text
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BoundingBox {
    /// Top-left x coordinate (normalized 0-1000)
    pub x1: f32,
    /// Top-left y coordinate (normalized 0-1000)
    pub y1: f32,
    /// Bottom-right x coordinate (normalized 0-1000)
    pub x2: f32,
    /// Bottom-right y coordinate (normalized 0-1000)
    pub y2: f32,
    /// Optional reference text associated with this box
    pub text: Option<String>,
}

impl BoundingBox {
    /// Convert normalized coordinates (0-1000) to pixel coordinates
    pub fn to_pixels(&self, img_width: u32, img_height: u32) -> (i32, i32, i32, i32) {
        let x1 = ((self.x1 / 1000.0) * img_width as f32) as i32;
        let y1 = ((self.y1 / 1000.0) * img_height as f32) as i32;
        let x2 = ((self.x2 / 1000.0) * img_width as f32) as i32;
        let y2 = ((self.y2 / 1000.0) * img_height as f32) as i32;
        (x1, y1, x2, y2)
    }
}

/// Extract bounding boxes from DeepSeek-OCR markdown output
pub fn extract_bounding_boxes(text: &str) -> Result<Vec<BoundingBox>> {
    let mut boxes = Vec::new();
    
    // Pattern for DeepSeek-OCR grounding format: <|det|>[[x1,y1,x2,y2]]<|/det|>
    let det_re = Regex::new(
        r"<\|det\|>\[\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]\]<\|/det\|>"
    )?;
    
    // Pattern for <|ref|>text<|/ref|> followed by detection
    let ref_det_re = Regex::new(
        r"<\|ref\|>([^<]+)<\|/ref\|>\s*<\|det\|>\[\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]\]<\|/det\|>"
    )?;
    
    // Legacy patterns for backward compatibility
    let ref_box_re = Regex::new(
        r"<ref>([^<]+)</ref>\s*<box>\[\[(\d+),(\d+)\],\[(\d+),(\d+)\]\]</box>"
    )?;
    let box_re = Regex::new(
        r"<box>\[\[(\d+),(\d+)\],\[(\d+),(\d+)\]\]</box>"
    )?;
    
    // First, extract ref+det pairs (with reference text)
    for cap in ref_det_re.captures_iter(text) {
        let text_content = cap.get(1).map(|m| m.as_str().to_string());
        let x1: f32 = cap[2].parse()?;
        let y1: f32 = cap[3].parse()?;
        let x2: f32 = cap[4].parse()?;
        let y2: f32 = cap[5].parse()?;
        
        boxes.push(BoundingBox {
            x1,
            y1,
            x2,
            y2,
            text: text_content,
        });
    }
    
    // Then extract standalone detection boxes (without already captured refs)
    let text_without_refs = ref_det_re.replace_all(text, "");
    for cap in det_re.captures_iter(&text_without_refs) {
        let x1: f32 = cap[1].parse()?;
        let y1: f32 = cap[2].parse()?;
        let x2: f32 = cap[3].parse()?;
        let y2: f32 = cap[4].parse()?;
        
        boxes.push(BoundingBox {
            x1,
            y1,
            x2,
            y2,
            text: None,
        });
    }
    
    // Legacy format support: <ref>text</ref><box>[[x1,y1],[x2,y2]]</box>
    for cap in ref_box_re.captures_iter(text) {
        let text_content = cap.get(1).map(|m| m.as_str().to_string());
        let x1: f32 = cap[2].parse()?;
        let y1: f32 = cap[3].parse()?;
        let x2: f32 = cap[4].parse()?;
        let y2: f32 = cap[5].parse()?;
        
        boxes.push(BoundingBox {
            x1,
            y1,
            x2,
            y2,
            text: text_content,
        });
    }
    
    // Legacy format: standalone boxes
    let text_without_legacy_refs = ref_box_re.replace_all(&text_without_refs, "");
    for cap in box_re.captures_iter(&text_without_legacy_refs) {
        let x1: f32 = cap[1].parse()?;
        let y1: f32 = cap[2].parse()?;
        let x2: f32 = cap[3].parse()?;
        let y2: f32 = cap[4].parse()?;
        
        boxes.push(BoundingBox {
            x1,
            y1,
            x2,
            y2,
            text: None,
        });
    }
    
    Ok(boxes)
}

/// Draw bounding boxes on an image
pub fn draw_bounding_boxes(
    image: &DynamicImage,
    boxes: &[BoundingBox],
) -> Result<DynamicImage> {
    let mut img = image.to_rgba8();
    let (width, height) = img.dimensions();
    
    // Load a basic font (embedded in the binary)
    let font_data = include_bytes!("../../../assets/DejaVuSans.ttf");
    let font = FontRef::try_from_slice(font_data)
        .map_err(|e| anyhow!("failed to load font: {}", e))?;
    
    let scale = PxScale::from(16.0);
    
    // Color palette for boxes
    let colors = [
        Rgba([255u8, 0u8, 0u8, 255u8]),     // Red
        Rgba([0u8, 255u8, 0u8, 255u8]),     // Green
        Rgba([0u8, 0u8, 255u8, 255u8]),     // Blue
        Rgba([255u8, 255u8, 0u8, 255u8]),   // Yellow
        Rgba([255u8, 0u8, 255u8, 255u8]),   // Magenta
        Rgba([0u8, 255u8, 255u8, 255u8]),   // Cyan
    ];
    
    for (idx, bbox) in boxes.iter().enumerate() {
        let (x1, y1, x2, y2) = bbox.to_pixels(width, height);
        
        // Ensure coordinates are within bounds
        let x1 = x1.max(0).min(width as i32 - 1);
        let y1 = y1.max(0).min(height as i32 - 1);
        let x2 = x2.max(0).min(width as i32);
        let y2 = y2.max(0).min(height as i32);
        
        let w = (x2 - x1).max(1) as u32;
        let h = (y2 - y1).max(1) as u32;
        
        let color = colors[idx % colors.len()];
        
        // Draw rectangle with 2px thickness
        let rect = Rect::at(x1, y1).of_size(w, h);
        draw_hollow_rect_mut(&mut img, rect, color);
        
        // Draw a second rectangle for thickness
        if x1 > 0 && y1 > 0 {
            let rect2 = Rect::at(x1 - 1, y1 - 1).of_size(w + 2, h + 2);
            draw_hollow_rect_mut(&mut img, rect2, color);
        }
        
        // Draw text label if present
        if let Some(ref text) = bbox.text {
            let label = format!("{}: {}", idx + 1, text);
            let text_y = (y1 - 20).max(0);
            draw_text_mut(&mut img, color, x1, text_y, scale, &font, &label);
        } else {
            let label = format!("{}", idx + 1);
            let text_y = (y1 - 20).max(0);
            draw_text_mut(&mut img, color, x1, text_y, scale, &font, &label);
        }
    }
    
    Ok(DynamicImage::ImageRgba8(img))
}

/// Remove bounding box tags from text for clean output
pub fn strip_bbox_tags(text: &str) -> String {
    // DeepSeek-OCR grounding format
    let ref_det_re = Regex::new(
        r"<\|ref\|>([^<]+)<\|/ref\|>\s*<\|det\|>\[\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]\]<\|/det\|>"
    ).unwrap();
    let det_re = Regex::new(
        r"<\|det\|>\[\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]\]<\|/det\|>"
    ).unwrap();
    
    // Legacy format
    let ref_box_re = Regex::new(
        r"<ref>([^<]+)</ref>\s*<box>\[\[(\d+),(\d+)\],\[(\d+),(\d+)\]\]</box>"
    ).unwrap();
    let box_re = Regex::new(
        r"<box>\[\[(\d+),(\d+)\],\[(\d+),(\d+)\]\]</box>"
    ).unwrap();
    
    // Replace ref+det with just the ref text
    let text = ref_det_re.replace_all(text, "$1");
    // Remove standalone detection boxes
    let text = det_re.replace_all(&text, "");
    // Legacy: Replace ref+box with just the ref text
    let text = ref_box_re.replace_all(&text, "$1");
    // Legacy: Remove standalone boxes
    let text = box_re.replace_all(&text, "");
    
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_extract_boxes_grounding_format() {
        let text = "Some text <|ref|>Title<|/ref|><|det|>[[100, 200, 300, 400]]<|/det|> more text <|det|>[[50, 60, 150, 160]]<|/det|>";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 2);
        assert_eq!(boxes[0].x1, 100.0);
        assert_eq!(boxes[0].y1, 200.0);
        assert_eq!(boxes[0].x2, 300.0);
        assert_eq!(boxes[0].y2, 400.0);
        assert_eq!(boxes[0].text, Some("Title".to_string()));
        
        assert_eq!(boxes[1].x1, 50.0);
        assert_eq!(boxes[1].y1, 60.0);
        assert_eq!(boxes[1].text, None);
    }
    
    #[test]
    fn test_extract_boxes_legacy_format() {
        let text = "Some text <ref>Title</ref><box>[[100,200],[300,400]]</box> more text <box>[[50,60],[150,160]]</box>";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 2);
        assert_eq!(boxes[0].x1, 100.0);
        assert_eq!(boxes[0].y1, 200.0);
        assert_eq!(boxes[0].text, Some("Title".to_string()));
        
        assert_eq!(boxes[1].x1, 50.0);
        assert_eq!(boxes[1].text, None);
    }
    
    #[test]
    fn test_extract_boxes_mixed_formats() {
        // Test that both grounding and legacy formats can coexist
        let text = "Start <|ref|>New Format<|/ref|><|det|>[[10, 20, 30, 40]]<|/det|> middle <ref>Old Format</ref><box>[[50,60],[70,80]]</box> end";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 2);
        
        // First box should be grounding format
        assert_eq!(boxes[0].x1, 10.0);
        assert_eq!(boxes[0].y1, 20.0);
        assert_eq!(boxes[0].x2, 30.0);
        assert_eq!(boxes[0].y2, 40.0);
        assert_eq!(boxes[0].text, Some("New Format".to_string()));
        
        // Second box should be legacy format
        assert_eq!(boxes[1].x1, 50.0);
        assert_eq!(boxes[1].y1, 60.0);
        assert_eq!(boxes[1].x2, 70.0);
        assert_eq!(boxes[1].y2, 80.0);
        assert_eq!(boxes[1].text, Some("Old Format".to_string()));
    }
    
    #[test]
    fn test_extract_boxes_grounding_standalone() {
        // Test standalone detection boxes without reference text
        let text = "Text before <|det|>[[100, 200, 300, 400]]<|/det|> text after";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 1);
        assert_eq!(boxes[0].x1, 100.0);
        assert_eq!(boxes[0].y1, 200.0);
        assert_eq!(boxes[0].x2, 300.0);
        assert_eq!(boxes[0].y2, 400.0);
        assert_eq!(boxes[0].text, None);
    }
    
    #[test]
    fn test_extract_boxes_legacy_standalone() {
        // Test standalone legacy boxes without reference text
        let text = "Text before <box>[[100,200],[300,400]]</box> text after";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 1);
        assert_eq!(boxes[0].x1, 100.0);
        assert_eq!(boxes[0].y1, 200.0);
        assert_eq!(boxes[0].x2, 300.0);
        assert_eq!(boxes[0].y2, 400.0);
        assert_eq!(boxes[0].text, None);
    }
    
    #[test]
    fn test_extract_boxes_no_boxes() {
        // Test text with no bounding boxes
        let text = "Just some plain text without any boxes";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 0);
    }
    
    #[test]
    fn test_extract_boxes_with_spaces() {
        // Test that spaces in coordinates are handled correctly
        let text = "<|det|>[[  100  ,  200  ,  300  ,  400  ]]<|/det|>";
        let boxes = extract_bounding_boxes(text).unwrap();
        
        assert_eq!(boxes.len(), 1);
        assert_eq!(boxes[0].x1, 100.0);
        assert_eq!(boxes[0].y1, 200.0);
        assert_eq!(boxes[0].x2, 300.0);
        assert_eq!(boxes[0].y2, 400.0);
    }
    
    #[test]
    fn test_bounding_box_to_pixels() {
        let bbox = BoundingBox {
            x1: 100.0,
            y1: 200.0,
            x2: 300.0,
            y2: 400.0,
            text: None,
        };
        
        // Test conversion with 1000x1000 image
        let (x1, y1, x2, y2) = bbox.to_pixels(1000, 1000);
        assert_eq!(x1, 100);
        assert_eq!(y1, 200);
        assert_eq!(x2, 300);
        assert_eq!(y2, 400);
        
        // Test conversion with 2000x2000 image (should scale up)
        let (x1, y1, x2, y2) = bbox.to_pixels(2000, 2000);
        assert_eq!(x1, 200);
        assert_eq!(y1, 400);
        assert_eq!(x2, 600);
        assert_eq!(y2, 800);
        
        // Test conversion with 500x500 image (should scale down)
        let (x1, y1, x2, y2) = bbox.to_pixels(500, 500);
        assert_eq!(x1, 50);
        assert_eq!(y1, 100);
        assert_eq!(x2, 150);
        assert_eq!(y2, 200);
    }
    
    #[test]
    fn test_draw_bounding_boxes_creates_image() {
        // Create a simple test image
        let img = DynamicImage::new_rgb8(800, 600);
        
        let boxes = vec![
            BoundingBox {
                x1: 100.0,
                y1: 100.0,
                x2: 300.0,
                y2: 200.0,
                text: Some("Test Box".to_string()),
            },
        ];
        
        // Draw boxes on the image
        let result = draw_bounding_boxes(&img, &boxes);
        
        // Should succeed
        assert!(result.is_ok());
        
        let annotated = result.unwrap();
        
        // Image dimensions should be preserved
        assert_eq!(annotated.width(), 800);
        assert_eq!(annotated.height(), 600);
    }
    
    #[test]
    fn test_draw_bounding_boxes_empty() {
        // Create a simple test image
        let img = DynamicImage::new_rgb8(800, 600);
        
        // Empty boxes array
        let boxes = vec![];
        
        // Draw boxes on the image
        let result = draw_bounding_boxes(&img, &boxes);
        
        // Should succeed even with no boxes
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_draw_bounding_boxes_multiple() {
        // Create a simple test image
        let img = DynamicImage::new_rgb8(800, 600);
        
        let boxes = vec![
            BoundingBox {
                x1: 100.0,
                y1: 100.0,
                x2: 300.0,
                y2: 200.0,
                text: Some("Box 1".to_string()),
            },
            BoundingBox {
                x1: 400.0,
                y1: 300.0,
                x2: 600.0,
                y2: 500.0,
                text: Some("Box 2".to_string()),
            },
            BoundingBox {
                x1: 50.0,
                y1: 50.0,
                x2: 150.0,
                y2: 150.0,
                text: None,
            },
        ];
        
        // Draw boxes on the image
        let result = draw_bounding_boxes(&img, &boxes);
        
        // Should succeed with multiple boxes
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_strip_tags_grounding() {
        let text = "Text <|ref|>Label<|/ref|><|det|>[[1, 2, 3, 4]]<|/det|> and <|det|>[[5, 6, 7, 8]]<|/det|> end";
        let stripped = strip_bbox_tags(text);
        assert_eq!(stripped, "Text Label and  end");
    }
    
    #[test]
    fn test_strip_tags_legacy() {
        let text = "Text <ref>Label</ref><box>[[1,2],[3,4]]</box> and <box>[[5,6],[7,8]]</box> end";
        let stripped = strip_bbox_tags(text);
        assert_eq!(stripped, "Text Label and  end");
    }
    
    #[test]
    fn test_strip_tags_mixed() {
        let text = "Start <|ref|>New<|/ref|><|det|>[[1,2,3,4]]<|/det|> and <ref>Old</ref><box>[[5,6],[7,8]]</box> end";
        let stripped = strip_bbox_tags(text);
        assert_eq!(stripped, "Start New and Old end");
    }
    
    #[test]
    fn test_strip_tags_no_tags() {
        let text = "Just plain text without any tags";
        let stripped = strip_bbox_tags(text);
        assert_eq!(stripped, "Just plain text without any tags");
    }
}
