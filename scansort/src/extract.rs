//! Multi-format text extraction and fingerprinting.
//!
//! Port of the experiment's extract.rs. Supports PDF, Excel, Word, PPTX,
//! text files, and images. Computes SHA-256 and SimHash for every document.

use crate::types::*;
use std::path::Path;

/// Minimum characters to consider a page as having meaningful text.
const MIN_TEXT_CHARS: usize = 20;

// ---------------------------------------------------------------------------
// File type extension sets
// ---------------------------------------------------------------------------

const PDF_EXTS: &[&str] = &[".pdf"];
const EXCEL_EXTS: &[&str] = &[".xlsx", ".xls"];
const WORD_EXTS: &[&str] = &[".docx"];
const PPTX_EXTS: &[&str] = &[".pptx"];
const TEXT_EXTS: &[&str] = &[
    ".txt", ".csv", ".tsv", ".md", ".json", ".xml", ".html", ".htm",
    ".log", ".yaml", ".yml",
];
const IMAGE_EXTS: &[&str] = &[
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".tif", ".webp",
];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Extract text and compute fingerprints for any supported file.
///
/// Detects the file type by extension, extracts text (per-page where
/// applicable), and computes SHA-256 and SimHash fingerprints.
pub fn extract_file(file_path: &str) -> VaultResult<ExtractionResult> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    let sha256 = compute_sha256(path)?;
    let file_type = detect_file_type(file_path);

    match file_type.as_str() {
        "pdf" => extract_pdf(file_path, &sha256),
        "excel" => extract_excel(file_path, &sha256),
        "word" => extract_word(file_path, &sha256),
        "pptx" => extract_pptx(file_path, &sha256),
        "text" => extract_text_file(file_path, &sha256),
        "image" => extract_image(file_path, &sha256),
        _ => extract_unknown(file_path, &sha256),
    }
}

// ---------------------------------------------------------------------------
// File type detection
// ---------------------------------------------------------------------------

fn detect_file_type(path: &str) -> String {
    let ext = Path::new(path)
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    if PDF_EXTS.contains(&ext.as_str()) {
        "pdf".to_string()
    } else if EXCEL_EXTS.contains(&ext.as_str()) {
        "excel".to_string()
    } else if WORD_EXTS.contains(&ext.as_str()) {
        "word".to_string()
    } else if PPTX_EXTS.contains(&ext.as_str()) {
        "pptx".to_string()
    } else if TEXT_EXTS.contains(&ext.as_str()) {
        "text".to_string()
    } else if IMAGE_EXTS.contains(&ext.as_str()) {
        "image".to_string()
    } else {
        "unknown".to_string()
    }
}

// ---------------------------------------------------------------------------
// Build result helper
// ---------------------------------------------------------------------------

fn build_result(
    full_text: &str,
    pages: Vec<PageInfo>,
    image_only: Vec<i32>,
    sha256: &str,
    file_type: &str,
) -> ExtractionResult {
    let simhash = compute_simhash(full_text);
    let simhash_hex = format!("{:016x}", simhash);

    ExtractionResult {
        success: true,
        file_type: file_type.to_string(),
        sha256: sha256.to_string(),
        simhash: simhash_hex,
        dhash: "0000000000000000".to_string(),
        page_count: pages.len() as i32,
        full_text: full_text.to_string(),
        char_count: full_text.len() as i64,
        image_only_pages: image_only,
        pages,
    }
}

// ---------------------------------------------------------------------------
// Per-format extractors
// ---------------------------------------------------------------------------

/// Extract text from a PDF using justpdf.
fn extract_pdf(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    let doc = match justpdf::Document::open(file_path) {
        Ok(d) => d,
        Err(e) => {
            return Err(VaultError::new(format!("Cannot open PDF: {e}")));
        }
    };

    let mut pages = Vec::new();
    let mut full_parts = Vec::new();
    let mut image_only = Vec::new();

    for i in 0..doc.page_count() {
        let page = match doc.page(i) {
            Ok(p) => p,
            Err(_) => {
                pages.push(PageInfo {
                    page_num: (i + 1) as i32,
                    has_text: false,
                    text: String::new(),
                    char_count: 0,
                });
                image_only.push((i + 1) as i32);
                continue;
            }
        };

        let text = match page.text() {
            Ok(t) => t.trim().to_string(),
            Err(_) => String::new(),
        };

        let cc = text.len();
        let has_text = cc >= MIN_TEXT_CHARS;

        pages.push(PageInfo {
            page_num: (i + 1) as i32,
            has_text,
            text: text.clone(),
            char_count: cc as i64,
        });

        if has_text {
            full_parts.push(text);
        } else {
            image_only.push((i + 1) as i32);
        }
    }

    let full_text = full_parts.join("\n\n");
    Ok(build_result(&full_text, pages, image_only, sha256, "pdf"))
}

/// Extract text from an Excel file using calamine.
fn extract_excel(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    use calamine::{open_workbook_auto, DataType, Reader};

    let mut workbook = open_workbook_auto(file_path)
        .map_err(|e| VaultError::new(format!("Cannot open Excel file: {e}")))?;

    let sheet_names = workbook.sheet_names().to_vec();
    let mut pages = Vec::new();
    let mut full_parts = Vec::new();

    for (i, sheet_name) in sheet_names.iter().enumerate() {
        let range = match workbook.worksheet_range(sheet_name) {
            Ok(r) => r,
            Err(_) => {
                pages.push(PageInfo {
                    page_num: (i + 1) as i32,
                    has_text: false,
                    text: String::new(),
                    char_count: 0,
                });
                continue;
            }
        };

        let mut rows_text = Vec::new();
        for row in range.rows() {
            let cells: Vec<String> = row.iter().map(|c| {
                if c.is_empty() {
                    String::new()
                } else {
                    format!("{c}")
                }
            }).collect();
            let line = cells.join("\t");
            let trimmed = line.trim().to_string();
            if !trimmed.is_empty() {
                rows_text.push(trimmed);
            }
        }

        let text = rows_text.join("\n");
        let cc = text.len();

        pages.push(PageInfo {
            page_num: (i + 1) as i32,
            has_text: cc >= MIN_TEXT_CHARS,
            text: text.clone(),
            char_count: cc as i64,
        });

        if !text.is_empty() {
            full_parts.push(format!("[Sheet: {sheet_name}]\n{text}"));
        }
    }

    let full_text = full_parts.join("\n\n");
    Ok(build_result(&full_text, pages, Vec::new(), sha256, "excel"))
}

/// Extract text from a Word (.docx) file using docx-rust.
///
/// Uses `body.text()` which returns all paragraph text joined with CRLF.
fn extract_word(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    use docx_rust::DocxFile;

    let docx_file = DocxFile::from_file(file_path)
        .map_err(|e| VaultError::new(format!("Cannot open Word file: {e}")))?;
    let docx = docx_file
        .parse()
        .map_err(|e| VaultError::new(format!("Cannot parse Word file: {e}")))?;

    let full_text = docx.document.body.text();
    let cc = full_text.len();

    let pages = vec![PageInfo {
        page_num: 1,
        has_text: cc >= MIN_TEXT_CHARS,
        text: full_text.clone(),
        char_count: cc as i64,
    }];

    Ok(build_result(&full_text, pages, Vec::new(), sha256, "word"))
}

/// PPTX: treated as image-only (no Rust crate for PPTX rendering).
/// The vision model will classify PPTX files.
fn extract_pptx(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    let _ = file_path;

    let pages = vec![PageInfo {
        page_num: 1,
        has_text: false,
        text: String::new(),
        char_count: 0,
    }];

    Ok(build_result("", pages, vec![1], sha256, "pptx"))
}

/// Extract text from a plain text file.
fn extract_text_file(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    let full_text = std::fs::read_to_string(file_path)
        .unwrap_or_else(|_| {
            let bytes = std::fs::read(file_path).unwrap_or_default();
            String::from_utf8_lossy(&bytes).to_string()
        });

    let cc = full_text.len();
    let pages = vec![PageInfo {
        page_num: 1,
        has_text: cc >= MIN_TEXT_CHARS,
        text: full_text.clone(),
        char_count: cc as i64,
    }];

    Ok(build_result(&full_text, pages, Vec::new(), sha256, "text"))
}

/// Images have no extractable text — flagged as image-only for vision model.
fn extract_image(_file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    let pages = vec![PageInfo {
        page_num: 1,
        has_text: false,
        text: String::new(),
        char_count: 0,
    }];

    Ok(build_result("", pages, vec![1], sha256, "image"))
}

/// Unknown files: try reading as text. If mostly printable, treat as text.
/// Otherwise flag as image-only for vision fallback.
fn extract_unknown(file_path: &str, sha256: &str) -> VaultResult<ExtractionResult> {
    if let Ok(sample) = std::fs::read_to_string(file_path) {
        let sample_slice = if sample.len() > 4096 {
            &sample[..4096]
        } else {
            &sample
        };

        let non_printable = sample_slice
            .chars()
            .filter(|c| !c.is_ascii_graphic() && !c.is_ascii_whitespace())
            .count();

        let total = sample_slice.len().max(1);
        if (non_printable as f64 / total as f64) < 0.1 {
            return extract_text_file(file_path, sha256);
        }
    }

    let pages = vec![PageInfo {
        page_num: 1,
        has_text: false,
        text: String::new(),
        char_count: 0,
    }];

    Ok(build_result("", pages, vec![1], sha256, "unknown"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_file_type() {
        assert_eq!(detect_file_type("report.pdf"), "pdf");
        assert_eq!(detect_file_type("data.xlsx"), "excel");
        assert_eq!(detect_file_type("data.xls"), "excel");
        assert_eq!(detect_file_type("doc.docx"), "word");
        assert_eq!(detect_file_type("slides.pptx"), "pptx");
        assert_eq!(detect_file_type("notes.txt"), "text");
        assert_eq!(detect_file_type("config.yaml"), "text");
        assert_eq!(detect_file_type("page.html"), "text");
        assert_eq!(detect_file_type("photo.jpg"), "image");
        assert_eq!(detect_file_type("photo.PNG"), "image");
        assert_eq!(detect_file_type("archive.zip"), "unknown");
    }

    #[test]
    fn test_build_result() {
        let result = build_result(
            "hello world test",
            vec![PageInfo {
                page_num: 1,
                has_text: true,
                text: "hello world test".to_string(),
                char_count: 16,
            }],
            Vec::new(),
            "abc123",
            "text",
        );
        assert!(result.success);
        assert_eq!(result.file_type, "text");
        assert_eq!(result.sha256, "abc123");
        assert_eq!(result.page_count, 1);
        assert_eq!(result.char_count, 16);
    }

    #[test]
    fn test_extract_text_file() {
        let dir = std::env::temp_dir().join("scansort_extract_test");
        let _ = std::fs::create_dir_all(&dir);
        let txt_path = dir.join("test.txt");
        let _ = std::fs::write(&txt_path, "Hello scansort\nLine 2\n");

        let result = extract_file(txt_path.to_str().unwrap()).unwrap();
        assert!(result.success);
        assert_eq!(result.file_type, "text");
        assert!(result.full_text.contains("Hello scansort"));
        assert!(!result.sha256.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_missing_file() {
        let result = extract_file("/nonexistent/path/to/file.txt");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message.contains("not found") || err.message.contains("File not found"));
    }
}
