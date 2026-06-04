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
    /// Optional CLI to launch in the role's pane (real Claude Code / Gemini
    /// CLI / aider / codex / etc.). Empty = use native chat backend.
    #[serde(default)]
    pub cli_command: String,
    /// First task prompt the team conductor sends to this role on launch.
    #[serde(default)]
    pub kickoff: String,
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
      "system_prompt": "You are the frontend engineer on the TaskHive project. Stack is Next.js 14 + Tailwind. When @backend ships a new endpoint, wire it into the dashboard. Defer auth questions to @security...",
      "cli_command": "claude",
      "kickoff": "Hi @frontend — please scaffold the marketing site at app/(marketing)/. Use server components by default. When done, publish ui.page.created. Read PLAN.md first."
    }
  ]
}

Rules:
- 6 to 10 team members. Build a real mid-sized engineering team, not a skeleton.
  Cover ALL relevant disciplines for the project — examples (pick the ones that
  apply, add others as needed):
    frontend, backend, mobile (if mobile applies), api, ui-ux, design-system,
    qa (manual + e2e tests), security (appsec, OWASP), devops/sre,
    dba (schema, perf), data (analytics, pipelines), ml (if AI features),
    payments, growth, docs, product-manager, support-tooling.
  Split distinct concerns into separate specialists: e.g. `qa` and `security`
  are ALWAYS separate roles, never merged with backend. Same for `dba` vs
  `backend` on data-heavy projects, and `ui-ux` vs `frontend`.
- For every concern actually present in the project, assign one specialist.
  Err on the side of MORE coverage when the description implies scale
  (commerce, multi-tenant, payments, auth, mobile, AI). Don't bundle.
- Define rich handoff topics so the team operates like an org — e.g.
  api.added/api.contract.changed, schema.changed/migration.applied,
  ui.component.added, design.spec.ready, tests.failing/tests.passed,
  security.finding/security.cleared, deploy.ready/deploy.rolled_back,
  data.event.added. Publishers + subscribers must connect (no orphan topics).
- `name` is short kebab-case, unique.
- `project_slug` is kebab-case and filesystem-safe.
- emoji is a single grapheme.
- recommended_model is a real id (claude-opus-4-7, claude-sonnet-4-6,
  claude-haiku-4-5-20251001, qwen3-coder, llama3.2). Use opus only for the
  roles that need deep reasoning (security, dba, ml, product-manager); the
  rest sonnet/haiku.
- recommended_provider is "anthropic" or "ollama".
- `system_prompt` is 8–25 sentences, project-specific, names real folders
  the role owns, lists what they DO and what they DEFER to teammates by
  @name. End with one "Output:" line about voice/format.
- tools come from: shell, fs_read, fs_write, npm, pnpm, pip, cargo, go,
  docker, gh, flyctl, kubectl, terraform, psql, sqlite, prisma, semgrep,
  gitleaks, trivy, nmap, playwright, vite. Give each role its minimal set.
- claude_skills from: pdf, xlsx, docx, pptx, skill-creator,
  consolidate-memory, setup-cowork, grill-me, grill-with-docs, tdd,
  improve-codebase-architecture, diagnose, to-prd, to-issues.
  Per-role guidance:
    product-manager → grill-with-docs, to-prd, to-issues, docx
    ui-ux           → grill-me, pptx
    backend / frontend / mobile / api → tdd, diagnose, improve-codebase-architecture
    qa              → tdd, diagnose
    security        → diagnose
    devops          → diagnose, to-issues
    docs            → docx, to-prd
  Empty list if none fit. Skills are slash-commands the role can invoke.
- publishes/subscribes use dotted topic names (`area.event`).
- kickoff: a concrete first task this role should do RIGHT NOW. 2-5
  sentences, project-specific, references real folders/files. Acts as
  the start-of-project prompt the conductor sends to this role. End with
  the topic they should publish when done. This is the message that
  shows up in their pane on first launch.
- cli_command: pick the real coding-agent CLI the role should drive,
  based on its recommended_provider and recommended_model:
    anthropic -> "claude"
    gemini    -> "gemini --model <recommended_model>"
    ollama    -> "aider --model ollama_chat/<recommended_model> --yes-always"
  For non-engineering roles (product-manager, ui-ux, docs) leave
  cli_command as "" so the pane uses the native chat.
- output nothing outside the fenced JSON block.
"#;

pub const PM_SYSTEM_PROMPT: &str = r#"You are the PM agent inside Atelier, a multi-agent IDE.
Your job: given a snapshot of an EXISTING codebase (file tree + key config files + README), identify the tech stack and propose a real team of AI engineer specialists to work on this project.

Each role you propose becomes an actual agent in the IDE — write its `system_prompt`, list the Claude skills it should preload, declare event topics it publishes/subscribes for handoff, and write a concrete `kickoff` first-task message.

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
      "why": "owns the user-facing surface",
      "recommended_provider": "anthropic",
      "recommended_model": "claude-haiku-4-5-20251001",
      "tools": ["shell", "fs_read", "fs_write", "npm", "playwright"],
      "claude_skills": ["docx"],
      "publishes": ["ui.component.added", "ui.page.created"],
      "subscribes": ["api.contract.defined", "design.spec.ready"],
      "system_prompt": "You are the frontend engineer on this project. The stack is <stack>. Own <real folders>. Defer auth questions to @security, schema questions to @backend...",
      "cli_command": "claude",
      "kickoff": "Hi @frontend — based on @ui-ux's design.spec.ready, scaffold the contact form component in src/components/ContactForm.tsx. Wire it to POST to the backend endpoint. Publish ui.component.added when done."
    }
  ]
}

Rules:
- 4 to 8 team members. Cover the disciplines actually present in this
  codebase (frontend, backend, api, ui-ux, design-system, qa, security,
  devops, dba, docs, product-manager, etc.). Split distinct concerns
  into separate specialists — qa is always separate from backend,
  security separate from devops.
- Define rich handoff topics so the team operates like an org. Examples:
  api.contract.defined, api.implemented, schema.changed, migration.applied,
  ui.component.added, ui.page.created, design.spec.ready, design.tokens.ready,
  tests.passing, tests.failing, security.finding, security.cleared,
  deploy.ready, requirements.defined. Every publisher must have at least
  one subscriber and vice versa (no orphan topics).
- `name` is short kebab-case, unique within team.
- emoji is a single grapheme.
- recommended_model is a REAL id. Valid: claude-haiku-4-5-20251001,
  claude-opus-4-7, qwen3-coder, llama3.2, qwen2.5-coder:1.5b. Use
  claude-haiku-4-5-20251001 as the default for engineering roles.
- recommended_provider is "anthropic", "gemini", or "ollama".
- `system_prompt` is 8–20 sentences, project-specific, names real folders
  the role owns, lists what they DO vs DEFER to @other-roles. End with
  one "Output:" line about voice/format.
- tools drawn from: shell, fs_read, fs_write, npm, pnpm, pip, cargo, go,
  docker, gh, flyctl, kubectl, terraform, psql, sqlite, prisma, semgrep,
  gitleaks, trivy, playwright, vite.
- claude_skills from: pdf, xlsx, docx, pptx, skill-creator,
  consolidate-memory. Empty list if none fit.
- publishes/subscribes use dotted topic names (`area.event`).
- kickoff: 2-5 sentences, concrete first task RIGHT NOW, references real
  folders/files, ends with the topic the role should publish when done.
  This is what the conductor sends on first pane launch.
- cli_command: real CLI binary, derived from provider+model:
    anthropic -> "claude"
    gemini    -> "gemini --model <recommended_model>"
    ollama    -> "aider --model ollama_chat/<recommended_model> --yes-always"
  For non-coding roles (product-manager, ui-ux pure design, docs) leave
  cli_command as "" so the pane defaults to native chat.
- Output nothing outside the fenced JSON block.
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
            max_tokens: Some(16384),
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
            max_tokens: Some(16384),
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

    /// Regenerate a single role's next-step kickoff message based on what
    /// has already happened in the workspace. Returns 2-5 sentence prompt.
    ///
    /// `role_yaml`   — full role YAML (so the model knows responsibility + topics)
    /// `event_log`   — human-readable list of recent events: "@role -> topic: summary"
    /// `recent_work` — short paragraph of what this role did last (chat history)
    /// Orchestrate a new feature request. Given the full team + event log,
    /// return a plan: which roles need to act and the exact task each.
    /// Returns (plan_summary, vec![(role_name, task_prompt)]).
    pub async fn orchestrate_feature(
        &self,
        team_yaml: &str,
        event_log: &str,
        feature_text: &str,
    ) -> anyhow::Result<(String, Vec<(String, String)>)> {
        let sys = r#"You are the PM in Atelier. The user just requested a NEW feature on an existing project. You have the team yaml (roles + their topics) and the full event bus so far. Decide which roles must act, and write a concrete imperative task for each.

Reply ONLY with a single fenced JSON block matching:
{
  "plan_summary": "one sentence: who does what at a high level",
  "affected_roles": [
    { "role_name": "ui-ux", "task": "Update docs/design/spec.md section 3 to use glossy Apple-style gradients. Replace flat color tokens in docs/design/tokens.json with gradient tokens. Publish design.spec.ready and design.tokens.ready when done." },
    { "role_name": "design-system", "task": "Re-render Button, Input, FormGroup with new gloss tokens from docs/design/tokens.json. Update Storybook stories. Publish design.system.ready when done." }
  ]
}

Rules:
- Only include roles whose work genuinely changes for this feature. Skip roles untouched.
- Tasks are imperative ("Edit X to do Y."), reference real files/topics from team + event log, no placeholders.
- 2-4 sentences per task. End each with "Publish <topic> when done." using the role's existing handoffPublishes.
- Order roles by dependency (upstream first).
- Output ONLY the JSON, nothing outside the fence.
"#;
        let user = format!(
            "TEAM (yaml blob):\n{team_yaml}\n\nEVENT BUS so far:\n{events}\n\nUSER FEATURE REQUEST:\n{feature_text}\n\nReturn the orchestration plan.",
            team_yaml = team_yaml,
            events = if event_log.is_empty() { "(none)" } else { event_log },
            feature_text = feature_text,
        );
        let req = ChatRequest {
            model: self.model.clone(),
            system: Some(sys.into()),
            max_tokens: Some(4096),
            messages: vec![ChatMessage { role: "user".into(), content: user }],
        };
        let mut stream = self.provider.chat(req).await?;
        let mut full = String::new();
        while let Some(item) = stream.next().await {
            match item? {
                ChatDelta::Text(t) => full.push_str(&t),
                ChatDelta::Done { .. } => break,
            }
        }
        let body = extract_json(&full).ok_or_else(|| anyhow::anyhow!("no JSON in PM response"))?;
        #[derive(serde::Deserialize)]
        struct Plan {
            plan_summary: String,
            affected_roles: Vec<RolePlan>,
        }
        #[derive(serde::Deserialize)]
        struct RolePlan { role_name: String, task: String }
        let plan: Plan = serde_json::from_str(body)
            .map_err(|e| anyhow::anyhow!("parse plan: {e}\n--- raw ---\n{body}"))?;
        let pairs = plan.affected_roles.into_iter()
            .map(|r| (r.role_name, r.task))
            .collect();
        Ok((plan.plan_summary, pairs))
    }

    pub async fn regenerate_kickoff(
        &self,
        role_yaml: &str,
        event_log: &str,
        recent_work: &str,
    ) -> anyhow::Result<String> {
        let sys = r#"You are the PM agent in Atelier. A coding agent (CLI claude) needs its NEXT concrete task. Write a prompt that is IMMEDIATELY actionable — the agent will execute it verbatim.

Rules:
- Write as an imperative instruction TO the agent ("Create X.", "Edit Y to do Z."). Not a description.
- 2-5 sentences. First sentence states the ONE concrete deliverable. Following sentences add specifics (paths, formats, edge cases).
- Reference real folders / files / event topics from the role yaml + event log. Never use placeholders like <project>, <file>.
- If the role is BLOCKED on missing upstream events (cycle, deadlock), give it a best-effort task it can do RIGHT NOW with what's already published. Don't ask it to wait.
- End with: "Publish <exact.topic> when done." Pick the topic from the role's `handoff_topics.publishes` list.
- No markdown, no fences, no quotes around the output. Plain prose, single paragraph. Output ONLY the prompt text.
"#;
        let user = format!(
            "ROLE YAML:\n{role_yaml}\n\nRECENT EVENT BUS (oldest → newest):\n{event_log}\n\nWHAT THIS ROLE LAST DID:\n{recent_work}\n\nWrite the next 2-5 sentence task for this role NOW.",
            role_yaml = role_yaml,
            event_log = if event_log.is_empty() { "(none yet)" } else { event_log },
            recent_work = if recent_work.is_empty() { "(nothing yet)" } else { recent_work }
        );
        let req = ChatRequest {
            model: self.model.clone(),
            system: Some(sys.into()),
            max_tokens: Some(512),
            messages: vec![ChatMessage { role: "user".into(), content: user }],
        };
        let mut stream = self.provider.chat(req).await?;
        let mut out = String::new();
        while let Some(item) = stream.next().await {
            match item? {
                ChatDelta::Text(t) => out.push_str(&t),
                ChatDelta::Done { .. } => break,
            }
        }
        Ok(out.trim().trim_matches('"').to_string())
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
