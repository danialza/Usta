//! LLM provider abstraction + concrete implementations.
//!
//! v0 carries Anthropic (SSE) and Ollama (NDJSON). Streams are unified into
//! [`ChatDelta`] so the daemon can transport them generically.

use async_trait::async_trait;
use futures::{Stream, StreamExt};
use serde::{Deserialize, Serialize};
use std::pin::Pin;
use std::sync::Arc;

pub mod anthropic;
pub mod gemini;
pub mod ollama;
pub mod openai;
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

// ---- Agentic (tool-use) ----

/// A tool the model may call. `input_schema` is a JSON-Schema object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

/// Events emitted while running an agentic (tool-use) turn.
#[derive(Debug, Clone)]
pub enum AgentDelta {
    Text(String),
    ToolCall { id: String, name: String, input: serde_json::Value },
    ToolResult { id: String, name: String, output: String },
    Done { stop_reason: String },
}

pub type AgentStream =
    Pin<Box<dyn Stream<Item = anyhow::Result<AgentDelta>> + Send + 'static>>;

/// Async callback that executes a tool and returns its textual output.
pub type ToolExec = Arc<
    dyn Fn(String, serde_json::Value) -> futures::future::BoxFuture<'static, anyhow::Result<String>>
        + Send
        + Sync,
>;

#[async_trait]
pub trait Provider: Send + Sync {
    fn name(&self) -> &'static str;
    fn default_models(&self) -> Vec<String>;
    /// Whether the provider is configured (creds present, host reachable). Best-effort.
    async fn available(&self) -> bool;
    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream>;

    /// Agentic turn with tools. Default: tools unsupported -> fall back to plain
    /// chat (no tool calls). Anthropic overrides this.
    async fn chat_agentic(
        &self,
        req: ChatRequest,
        _tools: Vec<ToolSpec>,
        _exec: ToolExec,
    ) -> anyhow::Result<AgentStream> {
        let s = self.chat(req).await?;
        let mapped = async_stream::stream! {
            let mut s = s;
            while let Some(item) = s.next().await {
                match item {
                    Ok(ChatDelta::Text(t)) => yield Ok(AgentDelta::Text(t)),
                    Ok(ChatDelta::Done { stop_reason }) => { yield Ok(AgentDelta::Done { stop_reason }); return; }
                    Err(e) => { yield Err(e); return; }
                }
            }
        };
        Ok(Box::pin(mapped))
    }
}

pub type DynProvider = Arc<dyn Provider>;
