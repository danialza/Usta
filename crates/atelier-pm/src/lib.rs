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
    /// Full system prompt describing how this role should behave on THIS
    /// project. Generated dynamically by the PM.
    #[serde(default)]
    pub system_prompt: String,
    /// Provider id, default "anthropic".
    #[serde(default = "default_provider")]
    pub recommended_provider: String,
    /// Claude skill identifiers to install for this role (e.g. ["pdf",
    /// "xlsx"]). Picked from the catalogue at proposal time.
    #[serde(default)]
    pub claude_skills: Vec<String>,
    /// Topics this role will publish on / listen to for inter-agent
    /// handoffs (e.g. publishes ["api.added"], subscribes ["schema.changed"]).
    #[serde(default)]
    pub publishes: Vec<String>,
    #[serde(default)]
    pub subscribes: Vec<String>,
}

fn default_provider() -> String { "anthropic".into() }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceAnalysis {
    pub summary: String,
    pub stack: Vec<StackTag>,
    pub team: Vec<ProposedRole>,
}

/// Output of PM when proposing a brand-new project from a user idea.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectProposal {
    /// Human-friendly project name ("TaskHive").
    pub project_name: String,
    /// Slug for the folder name ("task-hive").
    pub project_slug: String,
    pub summary: String,
    pub stack: Vec<StackTag>,
    pub team: Vec<ProposedRole>,
    /// Optional one-paragraph plan / suggested first milestones.
    #[serde(default)]
    pub first_steps: String,
}

pub const PM_NEW_PROJECT_PROMPT: &str = r#"You are the PM agent inside Atelier, a multi-agent IDE.
The user has described a NEW project they want to build (no code yet).
Your job: turn the idea into a concrete project proposal — a name, a stack, and a small team of AI engineer specialists who will collaborate on it.

Each role you propose becomes an actual agent in the IDE — write its `system_prompt`, list the Claude skills it should preload, and declare what events it publishes/subscribes for inter-agent handoffs.

Reply ONLY with a single fenced JSON block. The JSON must match this schema:

{
  "project_name": "TaskHive",
  "project_slug": "task-hive",
  "summary": "one or two sentences describing the project.",
  "stack": [
    { "name": "Next.js 14", "category": "framework" },
    { "name": "PostgreSQL", "category": "database" }
  ],
  "first_steps": "one paragraph of what the team should tackle first.",
  "team": [
    {
      "name": "frontend",
      "emoji": "🎨",
      "why": "owns the user-facing surface",
      "recommended_provider": "anthropic",
      "recommended_model": "claude-sonnet-4-6",
      "tools": ["shell", "fs_read", "fs_write", "npm", "playwright"],
      "claude_skills": ["docx", "pdf"],
      "publishes": ["ui.component.added"],
      "subscribes": ["api.added", "schema.changed"],
      "system_prompt": "You are the frontend engineer on the TaskHive project. Stack is Next.js 14 + Tailwind. When @backend ships a new endpoint, wire it into the dashboard. Defer auth questions to @security..."
    }
  ]
}

Rules:
- 3 to 6 team members.
- `name` is short kebab-case, unique.
- `project_slug` is kebab-case and filesystem-safe.
- emoji is a single grapheme.
- recommended_model is a real id (claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5-20251001, qwen3-coder, llama3.2).
- recommended_provider is "anthropic" or "ollama".
- `system_prompt` is 6–20 sentences, project-specific, mentions teammates by @name when handing off.
- tools come from this set: shell, fs_read, fs_write, npm, pnpm, pip, cargo, go, docker, gh, flyctl, kubectl, terraform, psql, sqlite, prisma, semgrep, gitleaks, trivy, nmap, playwright, vite.
- claude_skills from: pdf, xlsx, docx, pptx, skill-creator, consolidate-memory, setup-cowork. Empty if none fit.
- publishes/subscribes use dotted topic names (`area.event`).
- output nothing outside the fenced JSON block.
"#;

pub const PM_SYSTEM_PROMPT: &str = r#"You are the PM agent inside Atelier, a multi-agent IDE.
Your job: given a snapshot of a codebase (file tree + key config files + README), identify the tech stack and propose a small team of AI engineer roles tailored to THIS specific project.

Each role you propose becomes an actual agent in the IDE — so you must write its full `system_prompt` describing how it should behave on this codebase.

Reply ONLY with a single fenced JSON block. The JSON must match this schema:

{
  "summary": "one or two sentences describing the project",
  "stack": [
    { "name": "Next.js 14", "category": "framework" },
    { "name": "PostgreSQL", "category": "database" }
  ],
  "team": [
    {
      "name": "frontend",
      "emoji": "🎨",
      "why": "the UI is built with React + Tailwind and ships a marketing site + dashboard",
      "recommended_provider": "anthropic",
      "recommended_model": "claude-sonnet-4-6",
      "tools": ["shell", "fs_read", "fs_write", "npm", "playwright"],
      "system_prompt": "You are a senior frontend engineer on the <project name> team. The stack is Next.js 14 + TypeScript + Tailwind. Focus on the marketing site (app/(marketing)/) and the dashboard (app/(app)/dashboard/). Prefer server components by default. When unsure about design, propose 2-3 options and defer the pick to @ui-ux..."
    }
  ]
}

Rules:
- 3 to 6 team members, no more, no less than 3.
- `name` must be a short kebab-case identifier (e.g. "frontend", "backend", "security", "payments"), unique within the team.
- emoji must be a single grapheme.
- recommended_model must be a real model id (claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5-20251001, qwen3-coder, llama3.2).
- recommended_provider must be "anthropic" or "ollama".
- `system_prompt` must be 6–20 sentences, specific to THIS project: reference real folders, files, frameworks you saw. Tell the role what to defer to other roles in the team (use @mentions of other role names). End with a one-line "Output" rule about format/voice.
- tools is a small set drawn from: shell, fs_read, fs_write, npm, pnpm, pip, cargo, go, docker, gh, flyctl, kubectl, terraform, psql, sqlite, prisma, semgrep, gitleaks, trivy, nmap, playwright, vite.
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

    /// Propose a brand-new project from a free-text user idea (no workspace yet).
    pub async fn propose_from_idea(&self, idea: &str) -> anyhow::Result<ProjectProposal> {
        let user_msg = format!(
            "Project idea from the user:\n\n{}\n\nPropose the project name, stack, first steps, and the team.",
            idea.trim()
        );
        let req = ChatRequest {
            model: self.model.clone(),
            system: Some(PM_NEW_PROJECT_PROMPT.into()),
            max_tokens: Some(8192),
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
        let body = extract_json(&full).ok_or_else(|| anyhow::anyhow!("no JSON in response"))?;
        let mut proposal: ProjectProposal = serde_json::from_str(body)
            .map_err(|e| anyhow::anyhow!("parse proposal JSON: {e}\n--- raw ---\n{body}"))?;
        // Sanitise slug.
        proposal.project_slug = sanitize_slug(&proposal.project_slug);
        Ok(proposal)
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
            max_tokens: Some(8192),
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

fn sanitize_slug(s: &str) -> String {
    let cleaned: String = s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c.to_ascii_lowercase() } else { '-' })
        .collect();
    let trimmed = cleaned.trim_matches('-').to_string();
    if trimmed.is_empty() { "atelier-project".into() } else { trimmed }
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
