//! Embedding wrapper. fastembed-rs uses ONNX runtime; first run downloads the
//! model (~30 MB) to a local cache.

use anyhow::Context;
use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use std::path::PathBuf;
use std::sync::Mutex;

pub struct EmbedderConfig {
    pub model: EmbeddingModel,
    pub cache_dir: PathBuf,
}

impl Default for EmbedderConfig {
    fn default() -> Self {
        Self {
            model: EmbeddingModel::BGESmallENV15,
            cache_dir: usta_core::default_data_dir().join("models"),
        }
    }
}

pub struct Embedder {
    inner: Mutex<TextEmbedding>,
}

impl Embedder {
    pub fn load(cfg: EmbedderConfig) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&cfg.cache_dir).ok();
        let opts = InitOptions::new(cfg.model)
            .with_cache_dir(cfg.cache_dir)
            .with_show_download_progress(true);
        let m = TextEmbedding::try_new(opts).context("init fastembed")?;
        Ok(Self { inner: Mutex::new(m) })
    }

    pub fn embed_batch(&self, texts: &[String]) -> anyhow::Result<Vec<Vec<f32>>> {
        let mut m = self.inner.lock().unwrap();
        let refs: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();
        let out = m.embed(refs, None)?;
        Ok(out)
    }

    pub fn embed_one(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let mut v = self.embed_batch(&[text.to_string()])?;
        Ok(v.pop().unwrap_or_default())
    }
}
