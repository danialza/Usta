//! LLM provider abstraction + concrete implementations.
//!
//! v0 carries Anthropic (SSE) and Ollama (NDJSON). Streams are unified into
//! [`ChatDelta`] so the daemon can transport them generically.

use async_trait::async_trait;
use futures::Stream;
use serde::{Deserialize, Serialize};
use std::pin::Pin;
use std::sync::Arc;

pub mod anthropic;
pub mod ollama;
pub mod registry;

pub use registry::ProviderRegistry;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub system: Option<String>,
    pub messages: Vec<ChatMessage>,
    pub max_tokens: Option<u32>,
}

#[derive(Debug, Clone)]
pub enum ChatDelta {
    Text(String),
    Done { stop_reason: String },
}

pub type ChatStream =
    Pin<Box<dyn Stream<Item = anyhow::Result<ChatDelta>> + Send + 'static>>;

#[async_trait]
pub trait Provider: Send + Sync {
    fn name(&self) -> &'static str;
    fn default_models(&self) -> Vec<String>;
    /// Whether the provider is configured (creds present, host reachable). Best-effort.
    async fn available(&self) -> bool;
    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream>;
}

pub type DynProvider = Arc<dyn Provider>;
