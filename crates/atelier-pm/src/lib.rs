//! PM orchestrator. Summarises a workspace and asks an LLM to identify the
//! tech stack and propose a specialist team.

pub mod summary;

use atelier_providers::{ChatDelta, ChatMessage, ChatRequest, DynProvider};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::path::Path;

pub use summary::WorkspaceSummary;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StackTag {
    pub name: String,
    /// Free-form: language / framework / database / infra / lib / ...
    #[serde(default)]
    pub category: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProposedRole {
    pub name: String,
    pub emoji: String,
    pub why: String,
    pub recommended_model: String,
    #[serde(default)]
    pub tools: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceAnalysis {
    pub summary: String,
    pub stack: Vec<StackTag>,
    pub team: Vec<ProposedRole>,
}

pub const PM_SYSTEM_PROMPT: &str = r#"You are the PM agent inside Atelier, a multi-agent IDE.
Your job: given a snapshot of a codebase (file tree + key config files + README), identify the tech stack and propose a small team of AI engineer roles tailored to the project.

Reply ONLY with a single fenced JSON block. The JSON must match this schema:

{
  "summary": "one or two sentences describing the project",
  "stack": [
    { "name": "Next.js 14",      "category": "framework" },
    { "name": "PostgreSQL",       "category": "database" }
  ],
  "team": [
    {
      "name": "Frontend Engineer",
      "emoji": "🎨",
      "why": "needed because the UI is built with React + Tailwind",
      "recommended_model": "claude-sonnet-4-6",
      "tools": ["shell", "fs_read", "fs_write"]
    }
  ]
}

Rules:
- 3 to 6 team members, no more.
- emojis must be a single grapheme.
- recommended_model must be a real model id (claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5-20251001, qwen3-coder).
- be specific about why each role is needed for THIS project, citing observed signals.
- output nothing outside the fenced JSON block.
"#;

pub struct Pm {
    provider: DynProvider,
    model: String,
}

impl Pm {
    pub fn new(provider: DynProvider, model: impl Into<String>) -> Self {
        Self { provider, model: model.into() }
    }

    /// Build a summary, call the provider, parse JSON.
    pub async fn analyze(&self, root: &Path) -> anyhow::Result<WorkspaceAnalysis> {
        let summary = summary::summarize(root)?;
        let user_msg = format!(
            "Workspace root: {}\n\n{}\n\nIdentify the stack and propose the team.",
            root.display(),
            summary.render(),
        );

        let req = ChatRequest {
            model: self.model.clone(),
            system: Some(PM_SYSTEM_PROMPT.into()),
            max_tokens: Some(2048),
            messages: vec![ChatMessage { role: "user".into(), content: user_msg }],
        };

        let mut stream = self.provider.chat(req).await?;
        let mut full = String::new();
        while let Some(item) = stream.next().await {
            match item? {
                ChatDelta::Text(t) => full.push_str(&t),
                ChatDelta::Done { .. } => break,
            }
        }
        parse_analysis(&full)
    }
}

fn parse_analysis(s: &str) -> anyhow::Result<WorkspaceAnalysis> {
    // Find ```json ... ``` block, else best-effort first {…} block.
    let body = extract_json(s).ok_or_else(|| anyhow::anyhow!("no JSON block in response"))?;
    serde_json::from_str::<WorkspaceAnalysis>(body)
        .map_err(|e| anyhow::anyhow!("parse analysis JSON: {e}\n--- raw ---\n{body}"))
}

fn extract_json(s: &str) -> Option<&str> {
    // Try fenced block first.
    for fence in ["```json", "```JSON", "```"] {
        if let Some(start) = s.find(fence) {
            let after = &s[start + fence.len()..];
            let after = after.trim_start_matches(['\r', '\n']);
            if let Some(end) = after.find("```") {
                return Some(after[..end].trim());
            }
        }
    }
    // Fallback: first '{' to matching '}'.
    let bytes = s.as_bytes();
    let start = bytes.iter().position(|&b| b == b'{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escape = false;
    for (i, &b) in bytes[start..].iter().enumerate() {
        if escape { escape = false; continue; }
        match b {
            b'\\' if in_string => escape = true,
            b'"' => in_string = !in_string,
            b'{' if !in_string => depth += 1,
            b'}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&s[start..start + i + 1]);
                }
            }
            _ => {}
        }
    }
    None
}
