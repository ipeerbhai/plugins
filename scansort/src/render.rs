//! Page rendering to base64-encoded PNGs for vision model classification.
//!
//! Port of the experiment's render.rs. Supports PDFs (via justpdf) and
//! image files (PNG, JPG, etc.) directly.

use crate::types::*;
use std::path::Path;

/// Image file extensions that can be rendered directly.
const IMAGE_EXTS: &[&str] = &[
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".tif", ".webp",
];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Render document pages to base64-encoded PNGs.
///
/// Dispatches to the right renderer based on file type:
/// - PDF: renders pages via justpdf
/// - Image: returns the image as base64 PNG (converting if needed)
/// - Other: returns an error (text files should use text classification)
pub fn render_pages(file_path: &str, max_pages: i32, dpi: i32) -> VaultResult<RenderResult> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    if IMAGE_EXTS.contains(&ext.as_str()) {
        render_image_file(file_path)
    } else if ext == ".pdf" {
        render_pdf_pages(file_path, max_pages, dpi)
    } else {
        Err(VaultError::new(format!(
            "Cannot render file type '{ext}': only PDF and image files are supported"
        )))
    }
}

// ---------------------------------------------------------------------------
// PDF rendering
// ---------------------------------------------------------------------------

/// Render PDF pages to base64 PNGs via justpdf.
fn render_pdf_pages(file_path: &str, max_pages: i32, dpi: i32) -> VaultResult<RenderResult> {
    let doc = justpdf::Document::open(file_path)
        .map_err(|e| VaultError::new(format!("Cannot open PDF: {e}")))?;

    let total_pages = doc.page_count();
    let render_count = std::cmp::min(total_pages, max_pages as usize);

    let mut pages = Vec::new();

    for i in 0..render_count {
        let page = match doc.page(i) {
            Ok(p) => p,
            Err(_) => continue,
        };

        let png_bytes = match page.render_png(dpi as f64) {
            Ok(data) => data,
            Err(_) => continue,
        };

        let b64 = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            &png_bytes,
        );

        pages.push(RenderedPage {
            page_num: (i + 1) as i32,
            base64: b64,
        });
    }

    let page_count = pages.len() as i32;
    Ok(RenderResult {
        success: true,
        pages,
        page_count,
    })
}

// ---------------------------------------------------------------------------
// Image rendering
// ---------------------------------------------------------------------------

/// Return an image file directly as base64 PNG, converting if needed.
fn render_image_file(file_path: &str) -> VaultResult<RenderResult> {
    let path = Path::new(file_path);
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    let raw = std::fs::read(path)?;

    let png_bytes = if ext == ".png" {
        raw
    } else {
        match image::load_from_memory(&raw) {
            Ok(img) => {
                let mut buf = std::io::Cursor::new(Vec::new());
                img.write_to(&mut buf, image::ImageFormat::Png)
                    .map_err(|e| VaultError::new(format!("Image conversion failed: {e}")))?;
                buf.into_inner()
            }
            Err(_) => {
                // Fallback: send raw bytes as base64 (original format)
                raw
            }
        }
    };

    let b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &png_bytes,
    );

    Ok(RenderResult {
        success: true,
        pages: vec![RenderedPage {
            page_num: 1,
            base64: b64,
        }],
        page_count: 1,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_pages_missing_file() {
        let result = render_pages("/nonexistent/file.pdf", 2, 96);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message.contains("not found") || err.message.contains("File not found"));
    }

    #[test]
    fn test_render_pages_unsupported_type() {
        let dir = std::env::temp_dir().join("scansort_render_test");
        let _ = std::fs::create_dir_all(&dir);
        let txt_path = dir.join("test.txt");
        let _ = std::fs::write(&txt_path, "hello");

        let result = render_pages(txt_path.to_str().unwrap(), 2, 96);
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
