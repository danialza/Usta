//! Ollama provider — POST /api/chat with stream:true, NDJSON response.

use crate::{
    AgentDelta, AgentStream, ChatDelta, ChatRequest, ChatStream, Provider, ToolExec, ToolSpec,
};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;

const DEFAULT_BASE: &str = "http://127.0.0.1:11434";

pub struct OllamaProvider {
    base_url: String,
    http: reqwest::Client,
}

impl OllamaProvider {
    pub fn from_env() -> Self {
        let base_url = std::env::var("OLLAMA_HOST").unwrap_or_else(|_| DEFAULT_BASE.into());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(600))
            .build()
            .expect("reqwest client");
        Self { base_url, http }
    }
}

#[derive(Serialize)]
struct ApiReq<'a> {
    model: &'a str,
    stream: bool,
    messages: Vec<ApiMsg<'a>>,
}

#[derive(Serialize)]
struct ApiMsg<'a> {
    role: &'a str,
    content: String,
}

#[derive(Deserialize, Debug)]
struct NdLine {
    #[serde(default)]
    message: Option<MsgInner>,
    #[serde(default)]
    done: bool,
    #[serde(default)]
    done_reason: Option<String>,
}

#[derive(Deserialize, Debug)]
struct MsgInner {
    #[serde(default)]
    content: String,
}

#[async_trait]
impl Provider for OllamaProvider {
    fn name(&self) -> &'static str { "ollama" }

    fn default_models(&self) -> Vec<String> {
        // Coder-capable, tool-calling models. Pull with e.g.
        //   ollama pull qwen2.5-coder:7b
        vec![
            // Fast + tiny (~1GB) — good for tests / low RAM
            "qwen2.5-coder:1.5b".into(),
            "qwen2.5-coder:3b".into(),
            "llama3.2:3b".into(),
            // Standard
            "qwen2.5-coder:7b".into(),
            "llama3.1:8b".into(),
            "qwen3-coder".into(),
        ]
    }

    async fn available(&self) -> bool {
        let url = format!("{}/api/tags", self.base_url);
        match self.http.get(&url).timeout(Duration::from_secs(2)).send().await {
            Ok(r) => r.status().is_success(),
            Err(_) => false,
        }
    }

    async fn chat(&self, req: ChatRequest) -> anyhow::Result<ChatStream> {
        let url = format!("{}/api/chat", self.base_url);
        let mut messages: Vec<ApiMsg> = Vec::new();
        if let Some(sys) = req.system.as_ref() {
            messages.push(ApiMsg { role: "system", content: sys.clone() });
        }
        for m in &req.messages {
            messages.push(ApiMsg { role: &m.role, content: m.text_content() });
        }

        let body = ApiReq { model: &req.model, stream: true, messages };
        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            let s = resp.status();
            let t = resp.text().await.unwrap_or_default();
            anyhow::bail!("ollama {s}: {t}");
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
                    if line.is_empty() { continue; }
                    let parsed: NdLine = match serde_json::from_str(line) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    if let Some(m) = parsed.message {
                        if !m.content.is_empty() {
                            yield ChatDelta::Text(m.content);
                        }
                    }
                    if parsed.done {
                        yield ChatDelta::Done {
                            stop_reason: parsed.done_reason.unwrap_or_else(|| "stop".into()),
                        };
                        return;
                    }
                }
            }
            yield ChatDelta::Done { stop_reason: "eof".into() };
        };

        Ok(Box::pin(stream))
    }

    async fn chat_agentic(
        &self,
        req: ChatRequest,
        tools: Vec<ToolSpec>,
        exec: ToolExec,
    ) -> anyhow::Result<AgentStream> {
        let url = format!("{}/api/chat", self.base_url);
        let http = self.http.clone();
        let model = req.model.clone();

        // Build message history (Ollama uses {role, content[, tool_calls]}).
        let mut messages: Vec<serde_json::Value> = Vec::new();
        if let Some(sys) = &req.system {
            messages.push(json!({ "role": "system", "content": sys }));
        }
        for m in &req.messages {
            messages.push(json!({ "role": m.role, "content": m.text_content() }));
        }

        let tools_json: Vec<serde_json::Value> = tools
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
                let mut body = json!({
                    "model": model,
                    "messages": messages,
                    "stream": false,
                });
                if !tools_json.is_empty() { body["tools"] = json!(tools_json); }

                let resp = http.post(&url).json(&body).send().await?;
                let status = resp.status();
                let bytes = resp.bytes().await?;
                if !status.is_success() {
                    Err(anyhow::anyhow!("ollama {status}: {}", String::from_utf8_lossy(&bytes)))?;
                }
                let v: serde_json::Value = serde_json::from_slice(&bytes)?;
                let msg = &v["message"];
                let text = msg["content"].as_str().unwrap_or("").to_string();
                if !text.is_empty() {
                    yield AgentDelta::Text(text.clone());
                }

                let calls = msg["tool_calls"].as_array().cloned().unwrap_or_default();
                if calls.is_empty() {
                    yield AgentDelta::Done {
                        stop_reason: v["done_reason"].as_str().unwrap_or("stop").to_string(),
                    };
                    return;
                }

                // Echo assistant turn (content + tool_calls) into history.
                messages.push(json!({
                    "role": "assistant",
                    "content": text,
                    "tool_calls": calls,
                }));

                for (i, call) in calls.iter().enumerate() {
                    let name = call["function"]["name"].as_str().unwrap_or("").to_string();
                    let input = call["function"]["arguments"].clone();
                    let id = format!("call_{_turn}_{i}");
                    yield AgentDelta::ToolCall { id: id.clone(), name: name.clone(), input: input.clone() };
                    let output = match (exec)(name.clone(), input).await {
                        Ok(o) => o,
                        Err(e) => format!("error: {e}"),
                    };
                    yield AgentDelta::ToolResult { id, name: name.clone(), output: output.clone() };
                    messages.push(json!({
                        "role": "tool",
                        "content": output,
                    }));
                }
            }
            yield AgentDelta::Done { stop_reason: "max_turns".into() };
        };

        Ok(Box::pin(stream))
    }
}
