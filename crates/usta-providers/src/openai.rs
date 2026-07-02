//! OpenAI provider (Chat Completions API).
//!
//! Text: POST /v1/chat/completions with stream=true (SSE).
//! Agentic: same endpoint, non-streamed, tool_calls loop.
//! Key from OPENAI_API_KEY. Optional OPENAI_BASE_URL for Azure / proxies.

use crate::{
    AgentDelta, AgentStream, ChatDelta, ChatRequest, ChatStream, Provider, ToolExec, ToolSpec,
};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde_json::json;
use std::time::Duration;

const DEFAULT_BASE: &str = "https://api.openai.com";

async fn post_with_retry(
    http: &reqwest::Client,
    url: &str,
    key: &str,
    body: &serde_json::Value,
) -> anyhow::Result<reqwest::Response> {
    let mut delay_ms = 600u64;
    let mut last_err = String::new();
    for attempt in 0..4 {
        let resp = http
            .post(url)
            .bearer_auth(key)
            .json(body)
            .send()
            .await?;
        let st = resp.status();
        if st.is_success() {
            return Ok(resp);
        }
        let code = st.as_u16();
        let retriable = matches!(code, 429 | 500 | 502 | 503 | 504);
        let text = resp.text().await.unwrap_or_default();
        if !retriable || attempt == 3 {
            anyhow::bail!("openai {st}: {text}");
        }
        last_err = format!("{st}: {text}");
        tracing::warn!(attempt, delay_ms, err = %last_err, "openai retry");
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        delay_ms = (delay_ms * 2).min(4000);
    }
    anyhow::bail!("openai exhausted retries: {last_err}");
}

pub struct OpenAiProvider {
    api_key: Option<String>,
    base_url: String,
    http: reqwest::Client,
}

impl OpenAiProvider {
    pub fn from_env() -> Self {
        let api_key = std::env::var("OPENAI_API_KEY")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let base_url = std::env::var("OPENAI_BASE_URL").unwrap_or_else(|_| DEFAULT_BASE.into());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .expect("reqwest client");
        Self { api_key, base_url, http }
    }

    /// Build the `messages` array. System prompt becomes a leading
    /// `{role:"system"}` entry (OpenAI carries it inline, not separate).
    fn messages(req: &ChatRequest) -> Vec<serde_json::Value> {
        let mut out: Vec<serde_json::Value> = Vec::new();
        if let Some(s) = &req.system {
            out.push(json!({ "role": "system", "content": s }));
        }
        for m in &req.messages {
            let role = if m.role == "model" { "assistant" } else { m.role.as_str() };
            out.push(json!({ "role": role, "content": m.content }));
        }
        out
    }
}

#[async_trait]
impl Provider for OpenAiProvider {
    fn name(&self) -> &'static str { "openai" }

    fn default_models(&self) -> Vec<String> {
        vec![
            "gpt-4o".into(),
            "gpt-4o-mini".into(),
            "gpt-4.1".into(),
            "gpt-4.1-mini".into(),
            "gpt-4.1-nano".into(),
            "o4-mini".into(),
            "o3-mini".into(),
        ]
    }

    async fn available(&self) -> bool { self.api_key.is_some() }

    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream> {
        let key = self.api_key.clone().ok_or_else(|| anyhow::anyhow!("OPENAI_API_KEY not set"))?;
        let url = format!("{}/v1/chat/completions", self.base_url);
        let mut body = json!({
            "model": req.model,
            "messages": Self::messages(&req),
            "stream": true,
        });
        if let Some(mt) = req.max_tokens {
            body["max_completion_tokens"] = json!(mt);
        }

        let resp = post_with_retry(&self.http, &url, &key, &body).await?;

        let stream = try_stream! {
            let mut bytes = resp.bytes_stream();
            let mut buf = String::new();
            while let Some(chunk) = bytes.next().await {
                let chunk = chunk?;
                buf.push_str(&String::from_utf8_lossy(&chunk));
                while let Some(idx) = buf.find('\n') {
                    let line = buf[..idx].to_string();
                    buf.drain(..idx + 1);
                    let line = line.trim();
                    let Some(data) = line.strip_prefix("data:") else { continue };
                    let data = data.trim();
                    if data.is_empty() { continue; }
                    if data == "[DONE]" {
                        yield ChatDelta::Done { stop_reason: "stop".into() };
                        return;
                    }
                    let v: serde_json::Value = match serde_json::from_str(data) { Ok(v) => v, Err(_) => continue };
                    if let Some(t) = v["choices"][0]["delta"]["content"].as_str() {
                        if !t.is_empty() { yield ChatDelta::Text(t.to_string()); }
                    }
                }
            }
            yield ChatDelta::Done { stop_reason: "stop".into() };
        };
        Ok(Box::pin(stream))
    }

    async fn chat_agentic(
        &self,
        req: ChatRequest,
        tools: Vec<ToolSpec>,
        exec: ToolExec,
    ) -> anyhow::Result<AgentStream> {
        let key = self.api_key.clone().ok_or_else(|| anyhow::anyhow!("OPENAI_API_KEY not set"))?;
        let url = format!("{}/v1/chat/completions", self.base_url);
        let http = self.http.clone();

        let mut messages = Self::messages(&req);
        let tool_defs: Vec<serde_json::Value> = tools
            .iter()
            .map(|t| json!({
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.input_schema,
                }
            }))
            .collect();

        let stream = try_stream! {
            let max_turns = 20;
            for _turn in 0..max_turns {
                let mut body = json!({ "model": req.model, "messages": messages });
                if !tool_defs.is_empty() { body["tools"] = json!(tool_defs); }

                let resp = post_with_retry(&http, &url, &key, &body).await?;
                let bytes = resp.bytes().await?;
                let v: serde_json::Value = serde_json::from_slice(&bytes)?;
                let msg = &v["choices"][0]["message"];

                if let Some(t) = msg["content"].as_str() {
                    if !t.is_empty() { yield AgentDelta::Text(t.to_string()); }
                }

                let calls = msg["tool_calls"].as_array().cloned().unwrap_or_default();
                if calls.is_empty() {
                    yield AgentDelta::Done { stop_reason: "stop".into() };
                    return;
                }

                // Echo the assistant turn (with its tool_calls) back into history.
                messages.push(msg.clone());

                for c in calls {
                    let id = c["id"].as_str().unwrap_or("").to_string();
                    let name = c["function"]["name"].as_str().unwrap_or("").to_string();
                    let args_str = c["function"]["arguments"].as_str().unwrap_or("{}");
                    let args: serde_json::Value =
                        serde_json::from_str(args_str).unwrap_or_else(|_| json!({}));
                    yield AgentDelta::ToolCall { id: id.clone(), name: name.clone(), input: args.clone() };
                    let output = match (exec)(name.clone(), args).await {
                        Ok(o) => o, Err(e) => format!("error: {e}"),
                    };
                    yield AgentDelta::ToolResult { id: id.clone(), name: name.clone(), output: output.clone() };
                    messages.push(json!({
                        "role": "tool",
                        "tool_call_id": id,
                        "content": output,
                    }));
                }
            }
            yield AgentDelta::Done { stop_reason: "max_turns".into() };
        };
        Ok(Box::pin(stream))
    }
}
