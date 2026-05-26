//! Ollama provider — POST /api/chat with stream:true, NDJSON response.

use crate::{ChatDelta, ChatRequest, ChatStream, Provider};
use async_stream::try_stream;
use async_trait::async_trait;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
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
        vec!["qwen3-coder".into(), "llama3.2".into()]
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
            messages.push(ApiMsg { role: &m.role, content: m.content.clone() });
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
}
