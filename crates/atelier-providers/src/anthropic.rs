//! Anthropic Messages API provider with SSE streaming.
//!
//! Endpoint:  POST https://api.anthropic.com/v1/messages
//! Headers:   x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//! Stream:    SSE events. We care about `content_block_delta` (text_delta) and
//!            `message_stop`.

use crate::{AgentDelta, AgentStream, ChatDelta, ChatRequest, ChatStream, Provider, ToolExec, ToolSpec};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;

const DEFAULT_BASE: &str = "https://api.anthropic.com";
const API_VERSION: &str = "2023-06-01";

/// Limit concurrent in-flight anthropic requests to keep us under Tier 1
/// 50-RPM cap. 2 concurrent + retry handles bursts (PM regen, OrchestrateFeature,
/// idle-watcher) without 429 storms.
static ANTHROPIC_GATE: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

pub struct AnthropicProvider {
    api_key: Option<String>,
    base_url: String,
    http: reqwest::Client,
}

/// POST with exponential backoff on 429/500/502/503/504. Up to 4 tries
/// (~0.6s + 1.2s + 2.4s ≈ 4s). Holds a global semaphore permit so we never
/// have more than 2 concurrent calls (Tier 1 50-RPM safe even with bursts).
async fn post_with_retry(
    http: &reqwest::Client,
    url: &str,
    body: &serde_json::Value,
    key: &str,
) -> anyhow::Result<reqwest::Response> {
    let _permit = ANTHROPIC_GATE.acquire().await.map_err(|e| anyhow::anyhow!(e))?;
    let mut delay_ms = 600u64;
    let mut last_err = String::new();
    for attempt in 0..4 {
        let resp = http.post(url)
            .header("x-api-key", key)
            .header("anthropic-version", API_VERSION)
            .header("content-type", "application/json")
            .json(body)
            .send()
            .await?;
        let st = resp.status();
        if st.is_success() { return Ok(resp); }
        let code = st.as_u16();
        let retriable = matches!(code, 429 | 500 | 502 | 503 | 504);
        let text = resp.text().await.unwrap_or_default();
        if !retriable || attempt == 3 {
            anyhow::bail!("anthropic {st}: {text}");
        }
        last_err = format!("{st}: {text}");
        tracing::warn!(attempt, delay_ms, "anthropic retry: {last_err}");
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        delay_ms = (delay_ms * 2).min(4000);
    }
    anyhow::bail!("anthropic exhausted retries: {last_err}");
}

impl AnthropicProvider {
    pub fn from_env() -> Self {
        let api_key = std::env::var("ANTHROPIC_API_KEY")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
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

        let body_v = serde_json::to_value(&body)?;
        let resp = post_with_retry(&self.http, &url, &body_v, &key).await?;

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

    async fn chat_agentic(
        &self,
        req: ChatRequest,
        tools: Vec<ToolSpec>,
        exec: ToolExec,
    ) -> anyhow::Result<AgentStream> {
        let key = self.api_key.clone().ok_or_else(|| anyhow::anyhow!("ANTHROPIC_API_KEY not set"))?;
        let url = format!("{}/v1/messages", self.base_url);
        let http = self.http.clone();
        let model = req.model.clone();
        let system = req.system.clone();
        let max_tokens = req.max_tokens.unwrap_or(2048);

        // Conversation history as raw JSON content blocks.
        let mut messages: Vec<serde_json::Value> = req
            .messages
            .iter()
            .map(|m| json!({ "role": m.role, "content": m.content }))
            .collect();

        let tools_json: Vec<serde_json::Value> = tools
            .iter()
            .map(|t| json!({
                "name": t.name,
                "description": t.description,
                "input_schema": t.input_schema,
            }))
            .collect();

        let stream = try_stream! {
            let max_turns = 20;
            for _turn in 0..max_turns {
                let mut body = json!({
                    "model": model,
                    "max_tokens": max_tokens,
                    "messages": messages,
                    "stream": true,
                });
                if let Some(s) = &system { body["system"] = json!(s); }
                if !tools_json.is_empty() { body["tools"] = json!(tools_json); }

                let resp = post_with_retry(&http, &url, &body, &key).await?;

                // SSE accumulation for this turn.
                // index -> (kind, text_or_json, id, name)
                #[derive(Default, Clone)]
                struct Blk { kind: String, text: String, json: String, id: String, name: String }
                let mut blocks: std::collections::BTreeMap<i64, Blk> = std::collections::BTreeMap::new();
                let mut stop_reason = String::from("end_turn");

                let mut byte_stream = resp.bytes_stream();
                let mut buf = String::new();
                'sse: while let Some(chunk) = byte_stream.next().await {
                    let chunk = chunk?;
                    buf.push_str(&String::from_utf8_lossy(&chunk));
                    while let Some(idx) = buf.find("\n\n") {
                        let raw = buf[..idx].to_string();
                        buf.drain(..idx + 2);
                        let mut data = String::new();
                        for line in raw.lines() {
                            if let Some(rest) = line.strip_prefix("data:") {
                                data.push_str(rest.trim_start());
                            }
                        }
                        if data.is_empty() || data == "[DONE]" { continue; }
                        let ev: serde_json::Value = match serde_json::from_str(&data) {
                            Ok(v) => v, Err(_) => continue,
                        };
                        match ev["type"].as_str() {
                            Some("content_block_start") => {
                                let i = ev["index"].as_i64().unwrap_or(0);
                                let cb = &ev["content_block"];
                                let mut b = Blk::default();
                                b.kind = cb["type"].as_str().unwrap_or("").to_string();
                                if b.kind == "tool_use" {
                                    b.id = cb["id"].as_str().unwrap_or("").to_string();
                                    b.name = cb["name"].as_str().unwrap_or("").to_string();
                                }
                                blocks.insert(i, b);
                            }
                            Some("content_block_delta") => {
                                let i = ev["index"].as_i64().unwrap_or(0);
                                let d = &ev["delta"];
                                match d["type"].as_str() {
                                    Some("text_delta") => {
                                        if let Some(t) = d["text"].as_str() {
                                            yield AgentDelta::Text(t.to_string());
                                            blocks.entry(i).or_default().text.push_str(t);
                                        }
                                    }
                                    Some("input_json_delta") => {
                                        if let Some(p) = d["partial_json"].as_str() {
                                            blocks.entry(i).or_default().json.push_str(p);
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            Some("message_delta") => {
                                if let Some(sr) = ev["delta"]["stop_reason"].as_str() {
                                    stop_reason = sr.to_string();
                                }
                            }
                            Some("message_stop") => { break 'sse; }
                            _ => {}
                        }
                    }
                }

                // Rebuild assistant content blocks + collect tool calls.
                let mut content: Vec<serde_json::Value> = Vec::new();
                let mut tool_uses: Vec<(String, String, serde_json::Value)> = Vec::new();
                for (_, b) in &blocks {
                    if b.kind == "text" {
                        content.push(json!({ "type": "text", "text": b.text }));
                    } else if b.kind == "tool_use" {
                        let input: serde_json::Value = if b.json.trim().is_empty() {
                            json!({})
                        } else {
                            serde_json::from_str(&b.json).unwrap_or(json!({}))
                        };
                        content.push(json!({ "type": "tool_use", "id": b.id, "name": b.name, "input": input }));
                        tool_uses.push((b.id.clone(), b.name.clone(), input));
                    }
                }

                if tool_uses.is_empty() {
                    yield AgentDelta::Done { stop_reason };
                    return;
                }

                messages.push(json!({ "role": "assistant", "content": content }));

                let mut tool_results: Vec<serde_json::Value> = Vec::new();
                for (id, name, input) in tool_uses {
                    yield AgentDelta::ToolCall { id: id.clone(), name: name.clone(), input: input.clone() };
                    let output = match (exec)(name.clone(), input).await {
                        Ok(o) => o,
                        Err(e) => format!("error: {e}"),
                    };
                    yield AgentDelta::ToolResult { id: id.clone(), name, output: output.clone() };
                    tool_results.push(json!({
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": output,
                    }));
                }
                messages.push(json!({ "role": "user", "content": tool_results }));
            }
            yield AgentDelta::Done { stop_reason: "max_turns".to_string() };
        };

        Ok(Box::pin(stream))
    }
}
