//! Naive line-window chunker. Good enough for v0; can swap for a syntactic
//! splitter later (tree-sitter ranges).

#[derive(Debug, Clone)]
pub struct Chunk {
    pub start_line: u32,
    pub end_line: u32,
    pub text: String,
}

/// Splits the input into overlapping windows of `window` lines, advancing
/// by `window - overlap` each step. 1-based line numbers.
pub fn chunk(text: &str, window: usize, overlap: usize) -> Vec<Chunk> {
    assert!(window > overlap, "window must exceed overlap");
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let step = window - overlap;
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        let end = (i + window).min(lines.len());
        let body = lines[i..end].join("\n");
        // skip chunks that are pure whitespace
        if !body.trim().is_empty() {
            out.push(Chunk {
                start_line: (i + 1) as u32,
                end_line: end as u32,
                text: body,
            });
        }
        if end == lines.len() {
            break;
        }
        i += step;
    }
    out
}
