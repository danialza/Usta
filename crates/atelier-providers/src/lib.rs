// LLM provider abstraction. Real implementations land in week 2 (Anthropic, Ollama).
//
// Trait sketch only — kept here so the workspace compiles end-to-end and the
// shape is reviewable now.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
}

#[async_trait]
pub trait Provider: Send + Sync {
    fn name(&self) -> &'static str;
    async fn chat(&self, req: ChatRequest) -> anyhow::Result<String>;
}
