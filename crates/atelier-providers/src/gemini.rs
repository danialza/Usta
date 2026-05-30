//! Google Gemini provider (free tier friendly).
//!
//! Text: streamGenerateContent (SSE). Agentic: generateContent loop with
//! functionDeclarations + functionCall/functionResponse.
//! Key from GEMINI_API_KEY (get a free key at https://aistudio.google.com).

use crate::{
    AgentDelta, AgentStream, ChatDelta, ChatRequest, ChatStream, Provider, ToolExec, ToolSpec,
};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde_json::json;
use std::time::Duration;

const DEFAULT_BASE: &str = "https://generativelanguage.googleapis.com";

pub struct GeminiProvider {
    api_key: Option<String>,
    base_url: String,
    http: reqwest::Client,
}

impl GeminiProvider {
    pub fn from_env() -> Self {
        let api_key = std::env::var("GEMINI_API_KEY").ok().filter(|s| !s.is_empty());
        let base_url = std::env::var("GEMINI_BASE_URL").unwrap_or_else(|_| DEFAULT_BASE.into());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .expect("reqwest client");
        Self { api_key, base_url, http }
    }

    fn role(r: &str) -> &'static str {
        // Gemini uses "user" and "model".
        if r == "assistant" || r == "model" { "model" } else { "user" }
    }
}

#[async_trait]
impl Provider for GeminiProvider {
    fn name(&self) -> &'static str { "gemini" }

    fn default_models(&self) -> Vec<String> {
        // Current valid IDs on v1beta (mid-2025). Older bare `gemini-1.5-flash`
        // returns 404; use suffixed variants.
        vec![
            "gemini-2.5-flash".into(),
            "gemini-2.0-flash".into(),
            "gemini-2.0-flash-lite".into(),
            "gemini-1.5-flash-002".into(),
            "gemini-1.5-flash-8b".into(),
            "gemini-2.5-pro".into(),
            "gemini-1.5-pro-002".into(),
        ]
    }

    async fn available(&self) -> bool { self.api_key.is_some() }

    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream> {
        let key = self.api_key.clone().ok_or_else(|| anyhow::anyhow!("GEMINI_API_KEY not set"))?;
        let url = format!(
            "{}/v1beta/models/{}:streamGenerateContent?alt=sse&key={}",
            self.base_url, req.model, key
        );
        let contents: Vec<serde_json::Value> = req
            .messages
            .iter()
            .map(|m| json!({ "role": Self::role(&m.role), "parts": [{ "text": m.content }] }))
            .collect();
        let mut body = json!({ "contents": contents });
        if let Some(s) = &req.system {
            body["systemInstruction"] = json!({ "parts": [{ "text": s }] });
        }

        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            let st = resp.status();
            let t = resp.text().await.unwrap_or_default();
            anyhow::bail!("gemini {st}: {t}");
        }

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
                    let v: serde_json::Value = match serde_json::from_str(data) { Ok(v) => v, Err(_) => continue };
                    if let Some(parts) = v["candidates"][0]["content"]["parts"].as_array() {
                        for p in parts {
                            if let Some(t) = p["text"].as_str() {
                                yield ChatDelta::Text(t.to_string());
                            }
                        }
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
        let key = self.api_key.clone().ok_or_else(|| anyhow::anyhow!("GEMINI_API_KEY not set"))?;
        let url = format!(
            "{}/v1beta/models/{}:generateContent?key={}",
            self.base_url, req.model, key
        );
        let http = self.http.clone();
        let system = req.system.clone();

        let mut contents: Vec<serde_json::Value> = req
            .messages
            .iter()
            .map(|m| json!({ "role": Self::role(&m.role), "parts": [{ "text": m.content }] }))
            .collect();

        let fn_decls: Vec<serde_json::Value> = tools
            .iter()
            .map(|t| json!({
                "name": t.name,
                "description": t.description,
                "parameters": t.input_schema,
            }))
            .collect();

        let stream = try_stream! {
            let max_turns = 20;
            for _turn in 0..max_turns {
                let mut body = json!({ "contents": contents });
                if let Some(s) = &system { body["systemInstruction"] = json!({ "parts": [{ "text": s }] }); }
                if !fn_decls.is_empty() {
                    body["tools"] = json!([{ "functionDeclarations": fn_decls }]);
                }

                let resp = http.post(&url).json(&body).send().await?;
                let status = resp.status();
                let bytes = resp.bytes().await?;
                if !status.is_success() {
                    Err(anyhow::anyhow!("gemini {status}: {}", String::from_utf8_lossy(&bytes)))?;
                }
                let v: serde_json::Value = serde_json::from_slice(&bytes)?;
                let parts = v["candidates"][0]["content"]["parts"].as_array().cloned().unwrap_or_default();

                let mut calls: Vec<(String, serde_json::Value)> = Vec::new();
                let mut model_parts: Vec<serde_json::Value> = Vec::new();
                for p in &parts {
                    if let Some(t) = p["text"].as_str() {
                        if !t.is_empty() { yield AgentDelta::Text(t.to_string()); }
                        model_parts.push(json!({ "text": t }));
                    } else if let Some(fc) = p.get("functionCall") {
                        let name = fc["name"].as_str().unwrap_or("").to_string();
                        let args = fc["args"].clone();
                        calls.push((name, args));
                        model_parts.push(p.clone());
                    }
                }

                if calls.is_empty() {
                    yield AgentDelta::Done { stop_reason: "stop".into() };
                    return;
                }

                contents.push(json!({ "role": "model", "parts": model_parts }));

                let mut resp_parts: Vec<serde_json::Value> = Vec::new();
                for (i, (name, args)) in calls.into_iter().enumerate() {
                    let id = format!("call_{_turn}_{i}");
                    yield AgentDelta::ToolCall { id: id.clone(), name: name.clone(), input: args.clone() };
                    let output = match (exec)(name.clone(), args).await {
                        Ok(o) => o, Err(e) => format!("error: {e}"),
                    };
                    yield AgentDelta::ToolResult { id, name: name.clone(), output: output.clone() };
                    resp_parts.push(json!({
                        "functionResponse": { "name": name, "response": { "result": output } }
                    }));
                }
                contents.push(json!({ "role": "user", "parts": resp_parts }));
            }
            yield AgentDelta::Done { stop_reason: "max_turns".into() };
        };
        Ok(Box::pin(stream))
    }
}
