//! Anthropic Messages API provider with SSE streaming.
//!
//! Endpoint:  POST https://api.anthropic.com/v1/messages
//! Headers:   x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//! Stream:    SSE events. We care about `content_block_delta` (text_delta) and
//!            `message_stop`.

use crate::{ChatDelta, ChatRequest, ChatStream, Provider};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

const DEFAULT_BASE: &str = "https://api.anthropic.com";
const API_VERSION: &str = "2023-06-01";

pub struct AnthropicProvider {
    api_key: Option<String>,
    base_url: String,
    http: reqwest::Client,
}

impl AnthropicProvider {
    pub fn from_env() -> Self {
        let api_key = std::env::var("ANTHROPIC_API_KEY").ok().filter(|s| !s.is_empty());
        let base_url = std::env::var("ANTHROPIC_BASE_URL")
            .unwrap_or_else(|_| DEFAULT_BASE.to_string());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .expect("reqwest client");
        Self { api_key, base_url, http }
    }
}

#[derive(Serialize)]
struct ApiReq<'a> {
    model: &'a str,
    max_tokens: u32,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<&'a str>,
    messages: Vec<ApiMsg<'a>>,
}

#[derive(Serialize)]
struct ApiMsg<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "type")]
enum SseEvent {
    #[serde(rename = "content_block_delta")]
    Delta { delta: DeltaInner },
    #[serde(rename = "message_delta")]
    MessageDelta { delta: MsgDelta },
    #[serde(rename = "message_stop")]
    MessageStop,
    #[serde(other)]
    Other,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "type")]
enum DeltaInner {
    #[serde(rename = "text_delta")]
    Text { text: String },
    #[serde(other)]
    Other,
}

#[derive(Deserialize, Debug, Default)]
struct MsgDelta {
    stop_reason: Option<String>,
}

#[async_trait]
impl Provider for AnthropicProvider {
    fn name(&self) -> &'static str { "anthropic" }

    fn default_models(&self) -> Vec<String> {
        vec![
            "claude-opus-4-7".into(),
            "claude-sonnet-4-6".into(),
            "claude-haiku-4-5-20251001".into(),
        ]
    }

    async fn available(&self) -> bool { self.api_key.is_some() }

    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream> {
        let key = self.api_key.clone().ok_or_else(|| {
            anyhow::anyhow!("ANTHROPIC_API_KEY not set")
        })?;
        let url = format!("{}/v1/messages", self.base_url);
        let body = ApiReq {
            model: &req.model,
            max_tokens: req.max_tokens.unwrap_or(1024),
            stream: true,
            system: req.system.as_deref(),
            messages: req.messages.iter().map(|m| ApiMsg {
                role: &m.role,
                content: &m.content,
            }).collect(),
        };

        let resp = self
            .http
            .post(&url)
            .header("x-api-key", key)
            .header("anthropic-version", API_VERSION)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let txt = resp.text().await.unwrap_or_default();
            anyhow::bail!("anthropic {status}: {txt}");
        }

        let stream = try_stream! {
            let mut byte_stream = resp.bytes_stream();
            let mut buf = String::new();
            let mut stop_reason = String::new();

            while let Some(chunk) = byte_stream.next().await {
                let chunk = chunk?;
                buf.push_str(&String::from_utf8_lossy(&chunk));

                // SSE messages separated by blank lines.
                while let Some(idx) = buf.find("\n\n") {
                    let raw = buf[..idx].to_string();
                    buf.drain(..idx + 2);

                    let mut data_lines = Vec::new();
                    for line in raw.lines() {
                        if let Some(rest) = line.strip_prefix("data:") {
                            data_lines.push(rest.trim_start());
                        }
                    }
                    if data_lines.is_empty() { continue; }
                    let data = data_lines.join("");
                    if data == "[DONE]" { continue; }

                    match serde_json::from_str::<SseEvent>(&data) {
                        Ok(SseEvent::Delta { delta: DeltaInner::Text { text } }) => {
                            yield ChatDelta::Text(text);
                        }
                        Ok(SseEvent::MessageDelta { delta }) => {
                            if let Some(sr) = delta.stop_reason {
                                stop_reason = sr;
                            }
                        }
                        Ok(SseEvent::MessageStop) => {
                            yield ChatDelta::Done {
                                stop_reason: std::mem::take(&mut stop_reason),
                            };
                            return;
                        }
                        _ => {}
                    }
                }
            }

            // Fallback Done if stream ended without explicit message_stop.
            yield ChatDelta::Done { stop_reason };
        };

        Ok(Box::pin(stream))
    }
}
