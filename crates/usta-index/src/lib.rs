//! Workspace indexer. Walks files (gitignore-aware), chunks by line windows,
//! embeds with fastembed (bge-small), persists into usta-core::db.
//!
//! Search is brute-force cosine for v0 — fine for tens of thousands of chunks.

pub mod chunker;
pub mod embed;
pub mod walker;

use usta_core::db::Db;
use std::path::Path;
use std::sync::Arc;

pub use embed::{Embedder, EmbedderConfig};

pub const EMBED_DIM: usize = 384; // bge-small-en-v1.5

#[derive(Debug, Clone)]
pub struct IndexProgress {
    pub files_seen: u64,
    pub files_indexed: u64,
    pub chunks: u64,
    pub current_path: String,
    pub done: bool,
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
    pub snippet: String,
    pub score: f32,
}

pub struct Indexer {
    db: Arc<Db>,
    embedder: Arc<Embedder>,
}

impl Indexer {
    pub fn new(db: Arc<Db>, embedder: Arc<Embedder>) -> Self {
        Self { db, embedder }
    }

    /// Walk + chunk + embed + persist. Calls `progress` periodically.
    pub fn index_workspace(
        &self,
        workspace_id: &str,
        root: &Path,
        mut progress: impl FnMut(IndexProgress),
    ) -> anyhow::Result<IndexProgress> {
        // Clear previous chunks/embeddings for this workspace.
        self.db.clear_index(workspace_id)?;

        let mut state = IndexProgress {
            files_seen: 0,
            files_indexed: 0,
            chunks: 0,
            current_path: String::new(),
            done: false,
        };

        // Collect chunks in batches and embed.
        let mut batch_text: Vec<String> = Vec::new();
        let mut batch_meta: Vec<(String, u32, u32, String)> = Vec::new(); // (path, start, end, text)
        const BATCH: usize = 32;

        let mut flush =
            |emb: &Embedder, db: &Db, ws: &str, texts: &mut Vec<String>, metas: &mut Vec<(String, u32, u32, String)>| -> anyhow::Result<u64> {
                if texts.is_empty() {
                    return Ok(0);
                }
                let vecs = emb.embed_batch(texts)?;
                let n = texts.len() as u64;
                for ((path, start, end, content), vec) in metas.drain(..).zip(vecs.into_iter()) {
                    db.insert_chunk(ws, &path, start, end, &content, &vec)?;
                }
                texts.clear();
                Ok(n)
            };

        for file in walker::walk(root) {
            state.files_seen += 1;
            state.current_path = file
                .strip_prefix(root)
                .unwrap_or(&file)
                .to_string_lossy()
                .into_owned();
            progress(state.clone());

            let bytes = match std::fs::read(&file) {
                Ok(b) => b,
                Err(_) => continue,
            };
            if !is_probably_text(&bytes) {
                continue;
            }
            let text = match std::str::from_utf8(&bytes) {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            };
            state.files_indexed += 1;

            let rel = file
                .strip_prefix(root)
                .unwrap_or(&file)
                .to_string_lossy()
                .into_owned();

            for ch in chunker::chunk(&text, 40, 8) {
                batch_text.push(ch.text.clone());
                batch_meta.push((rel.clone(), ch.start_line, ch.end_line, ch.text));
                if batch_text.len() >= BATCH {
                    let n = flush(
                        &self.embedder,
                        &self.db,
                        workspace_id,
                        &mut batch_text,
                        &mut batch_meta,
                    )?;
                    state.chunks += n;
                    progress(state.clone());
                }
            }
        }
        let n = flush(
            &self.embedder,
            &self.db,
            workspace_id,
            &mut batch_text,
            &mut batch_meta,
        )?;
        state.chunks += n;
        state.done = true;
        progress(state.clone());
        Ok(state)
    }

    pub fn search(&self, workspace_id: &str, query: &str, k: usize) -> anyhow::Result<Vec<SearchHit>> {
        let q = self.embedder.embed_one(query)?;
        let hits = self.db.cosine_topk(workspace_id, &q, k)?;
        Ok(hits
            .into_iter()
            .map(|(path, start, end, snippet, score)| SearchHit {
                path,
                start_line: start,
                end_line: end,
                snippet,
                score,
            })
            .collect())
    }
}

fn is_probably_text(b: &[u8]) -> bool {
    if b.is_empty() {
        return false;
    }
    let sample = &b[..b.len().min(8192)];
    // NUL byte → likely binary
    if sample.contains(&0) {
        return false;
    }
    // ASCII or valid UTF-8 prefix
    std::str::from_utf8(sample).is_ok()
        || std::str::from_utf8(&sample[..sample.len().saturating_sub(4)]).is_ok()
}
