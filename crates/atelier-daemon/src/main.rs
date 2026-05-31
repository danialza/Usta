mod toolexec;

use anyhow::Context;
use atelier_core::{
    db::{Db, TerminalRow, WorkspaceRow},
    default_data_dir, default_socket_path,
    pty::{PtyManager, TerminalSpec},
    tools::ToolRegistry,
};
use atelier_proto::v1::{
    atelier_server::{Atelier, AtelierServer},
    AnalyzeRequest, ApplyTeamRequest, ApplyTeamResponse, ChatRequest as PbChatReq, ChatToken,
    AddRoleRequest, AddRoleResponse, DeleteRoleRequest,
    CloseTerminalRequest, CloseWorkspaceRequest, CreateTerminalRequest, Empty, Event as PbEvent, EventList,
    GetHistoryRequest, HistoryList, HistoryMessage,
    IndexProgress as PbIndexProgress, IndexRequest, ListEventsRequest, ListRolesRequest,
    ListTerminalsRequest, ListToolsRequest, OpenWorkspaceRequest, PingRequest, PingResponse,
    ProjectProposal as PbProjectProposal, ProposeProjectRequest, ProposedRole as PbProposedRole,
    ApproveToolRequest, ProviderInfo, ProviderList, PtyClientMsg, PublishEventRequest,
    PtyServerMsg, Role as PbRole, RoleChatRequest, RoleList, ScaffoldProjectRequest,
    ScaffoldProjectResponse,
    SearchHit as PbSearchHit, SearchRequest, SearchResults, StackTag as PbStackTag,
    TeamChatEvent, TeamChatRequest, Terminal as PbTerminal, TerminalList, Tool as PbTool,
    ToolList, Workspace, WorkspaceAnalysis as PbAnalysis, WorkspaceList,
};
use atelier_roles::{Role as RoleDef, RoleLibrary};
use atelier_providers::{AgentDelta, ChatDelta, ChatMessage, ChatRequest, ProviderRegistry};
use atelier_index::{Embedder, EmbedderConfig, Indexer};
use tokio::sync::OnceCell;
use clap::Parser;
use futures::StreamExt;
use std::{path::PathBuf, pin::Pin, sync::Arc};
use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{transport::Server, Request, Response, Status, Streaming};
use tracing::{error, info, warn};

#[derive(Parser, Debug)]
#[command(name = "atelierd", version, about = "Atelier daemon")]
struct Args {
    #[arg(long)]
    socket: Option<PathBuf>,
    /// Override data dir (DB lives here).
    #[arg(long)]
    data_dir: Option<PathBuf>,
}

struct AtelierSvc {
    db: Arc<Db>,
    pty: Arc<PtyManager>,
    providers: Arc<ProviderRegistry>,
    embedder: Arc<OnceCell<Arc<Embedder>>>,
    roles: Arc<RoleLibrary>,
    tools: Arc<ToolRegistry>,
    approvals: Arc<tokio::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<bool>>>>,
    socket_path: String,
}

impl AtelierSvc {
    /// Build a RoleLibrary view that includes builtin/user roles plus any
    /// workspace-scoped roles found under <ws>/.atelier/roles/ when a
    /// workspace_id is provided.
    async fn effective_roles(&self, workspace_id: &str) -> Result<RoleLibrary, Status> {
        if workspace_id.is_empty() {
            return Ok((*self.roles).clone());
        }
        let db = self.db.clone();
        let ws_id = workspace_id.to_string();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces
            .into_iter()
            .find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{workspace_id}' not found")))?;
        Ok(self.roles.with_workspace(std::path::Path::new(&ws.path)))
    }

    async fn embedder(&self) -> Result<Arc<Embedder>, Status> {
        self.embedder
            .get_or_try_init(|| async {
                tokio::task::spawn_blocking(|| {
                    Embedder::load(EmbedderConfig::default()).map(Arc::new)
                })
                .await
                .map_err(|e| anyhow::anyhow!("join: {e}"))?
            })
            .await
            .map(Arc::clone)
            .map_err(|e| Status::internal(format!("embedder init: {e}")))
    }
}

type TokenStream = Pin<Box<dyn futures::Stream<Item = Result<ChatToken, Status>> + Send>>;
type PtyStream = Pin<Box<dyn futures::Stream<Item = Result<PtyServerMsg, Status>> + Send>>;
type IndexStream = Pin<Box<dyn futures::Stream<Item = Result<PbIndexProgress, Status>> + Send>>;
type TeamStream = Pin<Box<dyn futures::Stream<Item = Result<TeamChatEvent, Status>> + Send>>;

/// Extract `@role` mentions (ASCII letters / digits / `-` / `_`).
fn parse_mentions(msg: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = msg.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'@' {
            let start = i + 1;
            let mut end = start;
            while end < bytes.len()
                && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'-' || bytes[end] == b'_')
            {
                end += 1;
            }
            if end > start {
                let name = std::str::from_utf8(&bytes[start..end]).unwrap_or("").to_string();
                if !name.is_empty() && !out.contains(&name) {
                    out.push(name);
                }
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

/// Extract `[[handoff: topic | summary]]` markers from assistant text.
fn parse_handoffs(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("[[handoff:") {
        let after = &rest[start + "[[handoff:".len()..];
        let Some(end) = after.find("]]") else { break };
        let inner = &after[..end];
        if let Some((topic, summary)) = inner.split_once('|') {
            let topic = topic.trim().to_string();
            let summary = summary.trim().to_string();
            if !topic.is_empty() && !summary.is_empty() {
                out.push((topic, summary));
            }
        }
        rest = &after[end + 2..];
    }
    out
}

/// Fan an event out to every workspace role that subscribes to its topic
/// (except the publisher), running each as a headless agentic turn. Headless
/// turns may read but not write/shell (no human to approve), and their own
/// handoffs are recorded WITHOUT re-dispatching, to prevent storms.
fn dispatch_event(
    db: Arc<Db>,
    providers: Arc<ProviderRegistry>,
    lib: RoleLibrary,
    ws_id: String,
    ws_root: Option<std::path::PathBuf>,
    from_role: String,
    topic: String,
    summary: String,
) {
    for role in lib.iter() {
        if role.name == from_role {
            continue;
        }
        if !role.handoff_topics.subscribes.iter().any(|t| t == &topic) {
            continue;
        }
        let Some(provider) = providers.get(&role.default_provider) else { continue };
        let role = role.clone();
        let db = db.clone();
        let ws_id = ws_id.clone();
        let ws_root = ws_root.clone();
        let from = from_role.clone();
        let topic = topic.clone();
        let summary = summary.clone();
        tokio::spawn(async move {
            run_role_headless(db, provider, role, ws_id, ws_root, from, topic, summary).await;
        });
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_role_headless(
    db: Arc<Db>,
    provider: atelier_providers::DynProvider,
    role: RoleDef,
    ws_id: String,
    ws_root: Option<std::path::PathBuf>,
    from_role: String,
    topic: String,
    summary: String,
) {
    let user_msg = format!(
        "Team update from @{from_role} [{topic}]: {summary}\n\n\
         If this affects your area, take the necessary action now (you may read \
         files; writes/shell need a human, so describe them). If not relevant, \
         reply 'noted'."
    );

    let mut system = role.system_prompt.clone();
    system.push_str(&atelier_core::skills::render_block(&role.claude_skills));
    if !role.handoff_topics.publishes.is_empty() {
        system.push_str(&format!(
            "\n\n## Handoffs\nIf you complete something the team needs, end with:\n\
             [[handoff: <topic> | <summary>]]\nYour topics: {}\n",
            role.handoff_topics.publishes.join(", ")
        ));
    }

    // Read-only tools for headless turns.
    let tools = ws_root.as_ref().map(|_| toolexec::specs_for_role(&role)).unwrap_or_default();
    let exec_root = ws_root.clone();
    let exec_role = role.clone();
    let exec: atelier_providers::ToolExec = std::sync::Arc::new(move |name, input| {
        let root = exec_root.clone();
        let role = exec_role.clone();
        Box::pin(async move {
            let Some(root) = root else { return Err(anyhow::anyhow!("no workspace")) };
            match toolexec::gate(&role, &name) {
                toolexec::Gate::Allowed => toolexec::execute(root, role, name, input).await,
                _ => Ok(format!("⏸ {name} skipped (headless turn needs a human to approve)")),
            }
        })
    });

    let req = ChatRequest {
        model: role.default_model.clone(),
        system: Some(system),
        messages: vec![ChatMessage { role: "user".into(), content: user_msg.clone() }],
        max_tokens: Some(1536),
    };

    let Ok(mut stream) = provider.chat_agentic(req, tools, exec).await else { return };
    let mut full = String::new();
    while let Some(item) = stream.next().await {
        match item {
            Ok(AgentDelta::Text(t)) => full.push_str(&t),
            Ok(AgentDelta::Done { .. }) => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    // Persist the auto turn.
    let body = full.clone();
    let (db1, ws1, rn1) = (db.clone(), ws_id.clone(), role.name.clone());
    let um = user_msg.clone();
    let _ = tokio::task::spawn_blocking(move || {
        db1.insert_agent_msg(&ws1, &rn1, "user", &um, now_ms())
    }).await;
    if !body.trim().is_empty() {
        let (db2, ws2, rn2) = (db.clone(), ws_id.clone(), role.name.clone());
        let _ = tokio::task::spawn_blocking(move || {
            db2.insert_agent_msg(&ws2, &rn2, "assistant", &body, now_ms())
        }).await;
    }
    // Record (but do not re-dispatch) this role's own handoffs.
    let allowed = role.handoff_topics.publishes.clone();
    for (t, s) in parse_handoffs(&full) {
        if allowed.is_empty() || allowed.iter().any(|x| x == &t) {
            let (db3, ws3, rn3) = (db.clone(), ws_id.clone(), role.name.clone());
            let _ = tokio::task::spawn_blocking(move || {
                db3.insert_event(&ws3, &rn3, &t, &s, now_ms())
            }).await;
        }
    }
}

/// Locate the atelier-mcp binary (sibling of this daemon's executable).
fn atelier_mcp_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let cand = dir.join("atelier-mcp");
    if cand.exists() { Some(cand) } else { None }
}

/// Write a project .mcp.json registering the Atelier bus server, so
/// MCP-capable CLI agents (Claude Code) can publish/subscribe events.
/// Skips if a .mcp.json already exists (don't clobber user config).
fn write_mcp_config(cwd: &str) {
    let Some(mcp) = atelier_mcp_path() else { return };
    let path = std::path::Path::new(cwd).join(".mcp.json");
    if path.exists() { return; }
    let cfg = serde_json::json!({
        "mcpServers": {
            "atelier": { "command": mcp.to_string_lossy() }
        }
    });
    if let Ok(s) = serde_json::to_string_pretty(&cfg) {
        let _ = std::fs::write(&path, s);
    }
}

/// Pre-approve project MCP servers so Claude Code doesn't prompt every launch.
fn write_claude_settings(cwd: &str) {
    let dir = std::path::Path::new(cwd).join(".claude");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("settings.local.json");
    if path.exists() { return; }
    let cfg = serde_json::json!({ "enableAllProjectMcpServers": true });
    if let Ok(s) = serde_json::to_string_pretty(&cfg) {
        let _ = std::fs::write(&path, s);
    }
}

/// Remove every .yaml/.yml in the workspace roles dir so a fresh team
/// replaces (not merges with) the old one.
fn purge_role_yamls(dir: &std::path::Path) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for entry in rd.flatten() {
        let p = entry.path();
        if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
            if ext == "yaml" || ext == "yml" {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
}

fn sanitize_role_name(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect()
}

/// Build the system-prompt brief injected into `claude --append-system-prompt`.
fn render_role_brief(role: &RoleDef, workspace_path: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "You are the @{name} specialist on the Atelier team working in {ws}.\n\n",
        name = role.name,
        ws = workspace_path
    ));
    out.push_str(&role.system_prompt);
    out.push_str("\n\n## Your handoff topics\n");
    if !role.handoff_topics.publishes.is_empty() {
        out.push_str(&format!("You publish: {}\n", role.handoff_topics.publishes.join(", ")));
    }
    if !role.handoff_topics.subscribes.is_empty() {
        out.push_str(&format!("You subscribe: {}\n", role.handoff_topics.subscribes.join(", ")));
    }
    out.push_str(
        "\n## Atelier MCP tools (you are connected to the team event bus)\n\
         - publish_event(topic, summary): announce when you finish a milestone.\n\
         - list_events(topics?, limit?): see recent team activity.\n\
         - wait_for_event(topics, timeout_seconds?): block until upstream work lands.\n\
         Always publish_event when you complete a task that affects others.\n",
    );
    if !role.claude_skills.is_empty() {
        out.push_str(&format!(
            "\n## Claude skills available\n{}\n",
            role.claude_skills.iter().map(|s| format!("- {s}")).collect::<Vec<_>>().join("\n")
        ));
    }
    out
}

fn probe_socket_alive(path: &std::path::Path) -> bool {
    use std::os::unix::net::UnixStream;
    use std::time::Duration;
    match UnixStream::connect(path) {
        Ok(s) => { let _ = s.set_read_timeout(Some(Duration::from_millis(50))); true }
        Err(_) => false,
    }
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn ws_to_pb(w: &WorkspaceRow) -> Workspace {
    Workspace {
        id: w.id.clone(),
        path: w.path.clone(),
        name: w.name.clone(),
        opened_unix_ms: w.opened_unix_ms,
    }
}

fn proposal_to_pb(p: atelier_pm::ProjectProposal) -> PbProjectProposal {
    PbProjectProposal {
        project_name: p.project_name,
        project_slug: p.project_slug,
        summary: p.summary,
        first_steps: p.first_steps,
        stack: p.stack.into_iter().map(|t| PbStackTag { name: t.name, category: t.category }).collect(),
        team: p.team.into_iter().map(|r| PbProposedRole {
            name: r.name,
            emoji: r.emoji,
            why: r.why,
            recommended_model: r.recommended_model,
            tools: r.tools,
            system_prompt: r.system_prompt,
            recommended_provider: r.recommended_provider,
            claude_skills: r.claude_skills,
            publishes: r.publishes,
            subscribes: r.subscribes,
            cli_command: r.cli_command,
            kickoff: r.kickoff,
        }).collect(),
    }
}

fn role_from_proposed(pr: &PbProposedRole, roles_dir: &std::path::Path) -> RoleDef {
    let prompt = if pr.system_prompt.trim().is_empty() {
        format!("You are the {} specialist on this project. {}", pr.name, pr.why)
    } else {
        pr.system_prompt.clone()
    };
    RoleDef {
        name: pr.name.clone(),
        emoji: pr.emoji.clone(),
        description: pr.why.clone(),
        system_prompt: prompt,
        default_provider: if pr.recommended_provider.is_empty() { "anthropic".into() } else { pr.recommended_provider.clone() },
        default_model: pr.recommended_model.clone(),
        allowed_tools: pr.tools.clone(),
        permissions: Default::default(),
        claude_skills: pr.claude_skills.clone(),
        handoff_topics: atelier_roles::HandoffTopics {
            publishes: pr.publishes.clone(),
            subscribes: pr.subscribes.clone(),
        },
        cli_command: pr.cli_command.clone(),
        kickoff: pr.kickoff.clone(),
        source: roles_dir.join(format!("{}.yaml", pr.name)),
        scope: atelier_roles::RoleScope::Workspace,
    }
}

fn term_row_to_pb(t: &TerminalRow, alive: bool) -> PbTerminal {
    PbTerminal {
        id: t.id.clone(),
        workspace_id: t.workspace_id.clone(),
        shell: t.shell.clone(),
        cwd: t.cwd.clone(),
        created_unix_ms: t.created_unix_ms,
        alive,
    }
}

#[tonic::async_trait]
impl Atelier for AtelierSvc {
    async fn ping(&self, req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        let client = req.into_inner().client_name;
        Ok(Response::new(PingResponse {
            daemon_version: atelier_core::DAEMON_VERSION.into(),
            server_unix_ms: now_ms(),
            greeting: format!("hi {client}, atelierd here"),
        }))
    }

    async fn open_workspace(
        &self,
        req: Request<OpenWorkspaceRequest>,
    ) -> Result<Response<Workspace>, Status> {
        let path = PathBuf::from(req.into_inner().path);
        if !path.exists() {
            return Err(Status::not_found(format!("{} not found", path.display())));
        }
        let path_s = path.to_string_lossy().to_string();

        // Reuse existing row if any, else insert.
        let db = self.db.clone();
        let path_s2 = path_s.clone();
        let existing = tokio::task::spawn_blocking(move || db.get_workspace_by_path(&path_s2))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;

        let row = if let Some(mut r) = existing {
            r.opened_unix_ms = now_ms();
            let db = self.db.clone();
            let r2 = r.clone();
            tokio::task::spawn_blocking(move || db.upsert_workspace(&r2))
                .await
                .unwrap()
                .map_err(|e| Status::internal(e.to_string()))?;
            r
        } else {
            let name = path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "workspace".into());
            let r = WorkspaceRow {
                id: format!("ws_{}", uuid::Uuid::new_v4().simple()),
                path: path_s,
                name,
                opened_unix_ms: now_ms(),
            };
            let db = self.db.clone();
            let r2 = r.clone();
            tokio::task::spawn_blocking(move || db.upsert_workspace(&r2))
                .await
                .unwrap()
                .map_err(|e| Status::internal(e.to_string()))?;
            r
        };

        Ok(Response::new(ws_to_pb(&row)))
    }

    async fn list_workspaces(
        &self,
        _req: Request<Empty>,
    ) -> Result<Response<WorkspaceList>, Status> {
        let db = self.db.clone();
        let rows = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(WorkspaceList {
            items: rows.iter().map(ws_to_pb).collect(),
        }))
    }

    async fn close_workspace(
        &self,
        req: Request<CloseWorkspaceRequest>,
    ) -> Result<Response<Empty>, Status> {
        let id = req.into_inner().id;
        if id.is_empty() {
            return Err(Status::invalid_argument("id required"));
        }
        let db = self.db.clone();
        tokio::task::spawn_blocking(move || db.delete_workspace(&id))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(Empty {}))
    }

    async fn list_providers(
        &self,
        _req: Request<Empty>,
    ) -> Result<Response<ProviderList>, Status> {
        let mut items = Vec::new();
        for (name, p) in self.providers.iter() {
            items.push(ProviderInfo {
                name: name.clone(),
                available: p.available().await,
                default_models: p.default_models(),
            });
        }
        items.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(Response::new(ProviderList { items }))
    }

    type ChatStream = TokenStream;

    async fn chat(&self, req: Request<PbChatReq>) -> Result<Response<Self::ChatStream>, Status> {
        let r = req.into_inner();
        let provider = self
            .providers
            .get(&r.provider)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{}'", r.provider)))?;

        let req = ChatRequest {
            model: r.model,
            system: if r.system.is_empty() { None } else { Some(r.system) },
            messages: r
                .messages
                .into_iter()
                .map(|m| ChatMessage { role: m.role, content: m.content })
                .collect(),
            max_tokens: if r.max_tokens > 0 { Some(r.max_tokens as u32) } else { None },
        };

        let inner = match provider.chat(req).await {
            Ok(s) => s,
            Err(e) => {
                error!(error = %e, "provider chat failed");
                return Err(Status::internal(e.to_string()));
            }
        };

        let mapped = async_stream::stream! {
            let mut s = inner;
            while let Some(item) = s.next().await {
                match item {
                    Ok(ChatDelta::Text(t)) => {
                        yield Ok(ChatToken { text: t, ..Default::default() });
                    }
                    Ok(ChatDelta::Done { stop_reason }) => {
                        yield Ok(ChatToken { done: true, stop_reason, ..Default::default() });
                        return;
                    }
                    Err(e) => {
                        yield Ok(ChatToken { done: true, error: e.to_string(), ..Default::default() });
                        return;
                    }
                }
            }
        };
        Ok(Response::new(Box::pin(mapped) as Self::ChatStream))
    }

    async fn create_terminal(
        &self,
        req: Request<CreateTerminalRequest>,
    ) -> Result<Response<PbTerminal>, Status> {
        let r = req.into_inner();

        // Resolve workspace.
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let workspace = workspaces
            .into_iter()
            .find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;

        let shell = if r.shell.is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into())
        } else {
            r.shell
        };
        let cwd = if r.cwd.is_empty() { workspace.path.clone() } else { r.cwd };
        let cols = if r.cols > 0 { r.cols as u16 } else { 120 };
        let rows = if r.rows > 0 { r.rows as u16 } else { 32 };

        let id = format!("t_{}", uuid::Uuid::new_v4().simple());
        let has_command = !r.command.trim().is_empty();
        let mut extra_env: Vec<(String, String)> = Vec::new();
        // We may rewrite the launch command below to inject the role's
        // system prompt into `claude --append-system-prompt ...`.
        let mut effective_command = r.command.clone();
        if has_command {
            // Give the CLI agent + its MCP child the bus context.
            extra_env.push(("ATELIER_SOCKET".into(), self.socket_path.clone()));
            extra_env.push(("ATELIER_WORKSPACE_ID".into(), workspace.id.clone()));
            if !r.role.is_empty() {
                extra_env.push(("ATELIER_ROLE".into(), r.role.clone()));
            }
            // Write a project .mcp.json so MCP-capable CLIs (Claude Code) load
            // the Atelier bus server. Points at the atelier-mcp sibling binary.
            write_mcp_config(&cwd);
            // Allow MCP servers from this project without prompting.
            write_claude_settings(&cwd);

            // For claude (Claude Code) launches with a role: write a per-role
            // brief and append it to the system prompt so the CLI knows who it
            // is, what it owns, and how to use the Atelier bus.
            if !r.role.is_empty() && effective_command.trim_start().starts_with("claude") {
                let lib = self.roles.with_workspace(std::path::Path::new(&workspace.path));
                if let Some(role) = lib.get(&r.role) {
                    let brief = render_role_brief(role, &workspace.path);
                    let rel_brief =
                        format!(".atelier/agents/{}.md", sanitize_role_name(&r.role));
                    let abs_brief = std::path::PathBuf::from(&workspace.path).join(&rel_brief);
                    if let Some(parent) = abs_brief.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    let _ = std::fs::write(&abs_brief, brief);
                    // Rewrite: `claude [args]` -> `claude --append-system-prompt "$(cat .atelier/agents/<role>.md)" [args]`
                    let trimmed = effective_command.trim_start();
                    let (head, tail) = trimmed.split_once(char::is_whitespace).unwrap_or((trimmed, ""));
                    effective_command = format!(
                        "{head} --append-system-prompt \"$(cat {rel})\" {tail}",
                        head = head,
                        rel = rel_brief,
                        tail = tail
                    );
                }
            }
        }

        let spec = TerminalSpec {
            id: id.clone(),
            shell: shell.clone(),
            cwd: cwd.clone(),
            cols,
            rows,
            command: if has_command { Some(effective_command.clone()) } else { None },
            extra_env,
        };
        self.pty
            .create(spec)
            .await
            .map_err(|e| Status::internal(format!("pty create: {e}")))?;

        let created = now_ms();
        let row = TerminalRow {
            id: id.clone(),
            workspace_id: workspace.id.clone(),
            shell,
            cwd,
            created_unix_ms: created,
            closed_unix_ms: None,
        };
        let db = self.db.clone();
        let row2 = row.clone();
        tokio::task::spawn_blocking(move || db.insert_terminal(&row2))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;

        Ok(Response::new(term_row_to_pb(&row, true)))
    }

    async fn list_terminals(
        &self,
        req: Request<ListTerminalsRequest>,
    ) -> Result<Response<TerminalList>, Status> {
        let ws_filter = req.into_inner().workspace_id;
        let db = self.db.clone();
        let f = if ws_filter.is_empty() { None } else { Some(ws_filter) };
        let rows = tokio::task::spawn_blocking(move || db.list_terminals(f.as_deref()))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;

        let mut items = Vec::with_capacity(rows.len());
        for r in rows {
            let alive = self.pty.get(&r.id).await.map(|t| !t.is_closed()).unwrap_or(false);
            items.push(term_row_to_pb(&r, alive));
        }
        Ok(Response::new(TerminalList { items }))
    }

    async fn close_terminal(
        &self,
        req: Request<CloseTerminalRequest>,
    ) -> Result<Response<Empty>, Status> {
        let id = req.into_inner().id;
        self.pty.close(&id).await;
        let db = self.db.clone();
        let id2 = id.clone();
        tokio::task::spawn_blocking(move || db.close_terminal(&id2, now_ms()))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(Empty {}))
    }

    type StreamPtyStream = PtyStream;

    async fn stream_pty(
        &self,
        req: Request<Streaming<PtyClientMsg>>,
    ) -> Result<Response<Self::StreamPtyStream>, Status> {
        use atelier_proto::v1::pty_client_msg::Kind as CK;
        use atelier_proto::v1::pty_server_msg::Kind as SK;
        use atelier_proto::v1::{PtyError, PtyExit, PtyOutput};

        let mut inbound = req.into_inner();

        // Expect first frame = Attach.
        let first = inbound
            .next()
            .await
            .ok_or_else(|| Status::invalid_argument("empty stream"))??;
        let terminal_id = match first.kind {
            Some(CK::Attach(a)) => a.terminal_id,
            _ => return Err(Status::invalid_argument("first frame must be PtyAttach")),
        };

        let term = self
            .pty
            .get(&terminal_id)
            .await
            .ok_or_else(|| Status::not_found(format!("terminal '{terminal_id}' not found")))?;

        let mut out_rx = term.subscribe();
        let term_for_in = term.clone();

        // Spawn input pump.
        tokio::spawn(async move {
            while let Some(msg) = inbound.next().await {
                let Ok(msg) = msg else { break };
                match msg.kind {
                    Some(CK::Input(i)) => {
                        if term_for_in.write(&i.data).await.is_err() { break; }
                    }
                    Some(CK::Resize(r)) => {
                        let _ = term_for_in.resize(r.cols.max(1) as u16, r.rows.max(1) as u16).await;
                    }
                    Some(CK::Attach(_)) | None => {}
                }
            }
        });

        let term_for_out = term.clone();
        let outbound = async_stream::stream! {
            loop {
                tokio::select! {
                    msg = out_rx.recv() => {
                        match msg {
                            Ok(bytes) => {
                                yield Ok(PtyServerMsg {
                                    kind: Some(SK::Output(PtyOutput { data: bytes })),
                                });
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                                yield Ok(PtyServerMsg {
                                    kind: Some(SK::Error(PtyError {
                                        message: format!("lagged {n} chunks"),
                                    })),
                                });
                            }
                            Err(_) => break,
                        }
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_millis(250)) => {
                        if term_for_out.is_closed() {
                            yield Ok(PtyServerMsg {
                                kind: Some(SK::Exit(PtyExit { reason: "child exited".into() })),
                            });
                            break;
                        }
                    }
                }
            }
        };

        Ok(Response::new(Box::pin(outbound) as Self::StreamPtyStream))
    }

    type IndexWorkspaceStream = IndexStream;

    async fn index_workspace(
        &self,
        req: Request<IndexRequest>,
    ) -> Result<Response<Self::IndexWorkspaceStream>, Status> {
        let ws_id = req.into_inner().workspace_id;
        let db = self.db.clone();
        let ws_id2 = ws_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces
            .into_iter()
            .find(|w| w.id == ws_id2)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;

        let embedder = self.embedder().await?;
        let db = self.db.clone();

        let (tx, rx) = tokio::sync::mpsc::channel::<Result<PbIndexProgress, Status>>(32);

        tokio::task::spawn_blocking(move || {
            let indexer = Indexer::new(db, embedder);
            let root = std::path::PathBuf::from(&ws.path);
            let mut last_emit = std::time::Instant::now();
            let result = indexer.index_workspace(&ws.id, &root, |p| {
                // throttle progress emit to ~10/sec, always emit done.
                if p.done || last_emit.elapsed() > std::time::Duration::from_millis(100) {
                    let _ = tx.blocking_send(Ok(PbIndexProgress {
                        files_seen: p.files_seen,
                        files_indexed: p.files_indexed,
                        chunks: p.chunks,
                        current_path: p.current_path.clone(),
                        done: p.done,
                    }));
                    last_emit = std::time::Instant::now();
                }
            });
            if let Err(e) = result {
                let _ = tx.blocking_send(Err(Status::internal(format!("index: {e}"))));
            }
        });

        let stream = tokio_stream::wrappers::ReceiverStream::new(rx);
        Ok(Response::new(Box::pin(stream) as Self::IndexWorkspaceStream))
    }

    async fn list_roles(
        &self,
        req: Request<ListRolesRequest>,
    ) -> Result<Response<RoleList>, Status> {
        let ws_id = req.into_inner().workspace_id;
        let lib = self.effective_roles(&ws_id).await?;
        // If the workspace has its own roles, hide the builtin/user library
        // so the team view shows only THIS project's specialists.
        let has_ws_roles = !ws_id.is_empty()
            && lib.iter().any(|r| matches!(r.scope, atelier_roles::RoleScope::Workspace));
        let items = lib
            .iter()
            .filter(|r| !has_ws_roles || matches!(r.scope, atelier_roles::RoleScope::Workspace))
            .map(|r| PbRole {
                name: r.name.clone(),
                emoji: r.emoji.clone(),
                description: r.description.clone(),
                default_provider: r.default_provider.clone(),
                default_model: r.default_model.clone(),
                allowed_tools: r.allowed_tools.clone(),
                source_path: r.source.to_string_lossy().into_owned(),
                scope: r.scope.as_str().to_string(),
                claude_skills: r.claude_skills.clone(),
                handoff_publishes: r.handoff_topics.publishes.clone(),
                handoff_subscribes: r.handoff_topics.subscribes.clone(),
                cli_command: r.cli_command.clone(),
                kickoff: r.kickoff.clone(),
            })
            .collect();
        Ok(Response::new(RoleList { items }))
    }

    type RoleChatStream = TokenStream;

    async fn role_chat(
        &self,
        req: Request<RoleChatRequest>,
    ) -> Result<Response<Self::RoleChatStream>, Status> {
        let r = req.into_inner();
        let lib = self.effective_roles(&r.workspace_id).await?;
        let role = lib
            .get(&r.role_name)
            .cloned()
            .ok_or_else(|| Status::not_found(format!("role '{}' not found", r.role_name)))?;

        let provider_name = if r.provider.is_empty() { role.default_provider.clone() } else { r.provider };
        let model = if r.model.is_empty() { role.default_model.clone() } else { r.model };

        let provider = self
            .providers
            .get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;

        // Build augmented system prompt: role prompt + skills + subscribed
        // team activity + handoff instructions.
        let mut system = role.system_prompt.clone();
        system.push_str(&atelier_core::skills::render_block(&role.claude_skills));

        if !r.workspace_id.is_empty() && !role.handoff_topics.subscribes.is_empty() {
            let db = self.db.clone();
            let ws = r.workspace_id.clone();
            let topics = role.handoff_topics.subscribes.clone();
            let events = tokio::task::spawn_blocking(move || {
                db.list_events(&ws, &topics, 0, 12)
            })
            .await
            .unwrap()
            .unwrap_or_default();
            if !events.is_empty() {
                system.push_str("\n\n## Recent team activity (you subscribe to these)\n");
                for e in &events {
                    system.push_str(&format!("- @{} [{}]: {}\n", e.from_role, e.topic, e.summary));
                }
            }
        }

        if !role.handoff_topics.publishes.is_empty() {
            system.push_str(&format!(
                "\n\n## Handoffs\nWhen you complete work the rest of the team must know about, \
                 end your reply with a line of the form:\n[[handoff: <topic> | <one-line summary>]]\n\
                 Use one of these topics you own: {}\n",
                role.handoff_topics.publishes.join(", ")
            ));
        }

        // Resolve workspace root (for tool execution) if a workspace is set.
        let ws_root: Option<std::path::PathBuf> = if r.workspace_id.is_empty() {
            None
        } else {
            let db = self.db.clone();
            let ws_id = r.workspace_id.clone();
            let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
                .await
                .unwrap()
                .map_err(|e| Status::internal(e.to_string()))?;
            workspaces.into_iter().find(|w| w.id == ws_id).map(|w| std::path::PathBuf::from(w.path))
        };

        // Build tool specs + executor (only when we have a workspace root).
        let tools = if ws_root.is_some() { toolexec::specs_for_role(&role) } else { vec![] };

        if !tools.is_empty() {
            let tool_names: Vec<String> = tools.iter().map(|t| t.name.clone()).collect();
            system.push_str(&format!(
                "\n\n## Tools\nYou can call these tools to act on the workspace: {}. \
                 Paths are workspace-relative. Prefer reading before writing.\n",
                tool_names.join(", ")
            ));
        }

        let user_msg_for_history = r.user_msg.clone();
        let req = ChatRequest {
            model,
            system: Some(system),
            messages: vec![ChatMessage { role: "user".into(), content: r.user_msg }],
            max_tokens: if r.max_tokens > 0 { Some(r.max_tokens as u32) } else { Some(2048) },
        };

        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let role_name = role.name.clone();
        let allowed_pub = role.handoff_topics.publishes.clone();

        // Persist the user message.
        if !ws_id.is_empty() {
            let db2 = db.clone();
            let ws2 = ws_id.clone();
            let rn = role_name.clone();
            let um = user_msg_for_history.clone();
            let _ = tokio::task::spawn_blocking(move || {
                db2.insert_agent_msg(&ws2, &rn, "user", &um, now_ms())
            }).await;
        }

        // For auto inter-agent dispatch on handoff.
        let dispatch_providers = self.providers.clone();
        let dispatch_roles = self.roles.clone();
        let dispatch_ws_root = ws_root.clone();

        // Approval channel: exec sends (call_id, name, input) when a tool
        // needs user approval; the mapped stream forwards it to the client.
        let (areq_tx, mut areq_rx) =
            tokio::sync::mpsc::unbounded_channel::<(String, String, String)>();
        let approvals = self.approvals.clone();

        // Executor closure: gate -> (run | ask | deny).
        let exec_root = ws_root.clone();
        let exec_role = role.clone();
        let exec: atelier_providers::ToolExec = std::sync::Arc::new(move |name, input| {
            let root = exec_root.clone();
            let role = exec_role.clone();
            let approvals = approvals.clone();
            let areq_tx = areq_tx.clone();
            Box::pin(async move {
                let root = match root {
                    Some(r) => r,
                    None => return Err(anyhow::anyhow!("no workspace; tools unavailable")),
                };
                match toolexec::gate(&role, &name) {
                    toolexec::Gate::Denied => {
                        Ok(format!("⛔ {name} denied by role policy"))
                    }
                    toolexec::Gate::Allowed => {
                        toolexec::execute(root, role, name, input).await
                    }
                    toolexec::Gate::Ask => {
                        let id = format!("call_{}", uuid::Uuid::new_v4().simple());
                        let (tx, rx) = tokio::sync::oneshot::channel::<bool>();
                        approvals.lock().await.insert(id.clone(), tx);
                        let _ = areq_tx.send((id.clone(), name.clone(), input.to_string()));
                        match rx.await {
                            Ok(true) => toolexec::execute(root, role, name, input).await,
                            _ => Ok(format!("⛔ {name} denied by user")),
                        }
                    }
                }
            })
        });

        let inner = match provider.chat_agentic(req, tools, exec).await {
            Ok(s) => s,
            Err(e) => return Err(Status::internal(e.to_string())),
        };

        let mapped = async_stream::stream! {
            let mut s = inner;
            let mut full = String::new();
            loop {
                tokio::select! {
                    biased;
                    Some((id, name, input)) = areq_rx.recv() => {
                        yield Ok(ChatToken {
                            tool_name: name, tool_input: input,
                            needs_approval: true, tool_call_id: id,
                            ..Default::default()
                        });
                    }
                    item = s.next() => {
                        let Some(item) = item else { break };
                        match item {
                            Ok(AgentDelta::Text(t)) => {
                                full.push_str(&t);
                                yield Ok(ChatToken { text: t, ..Default::default() });
                            }
                            Ok(AgentDelta::ToolCall { name, input, .. }) => {
                                yield Ok(ChatToken { tool_name: name, tool_input: input.to_string(), ..Default::default() });
                            }
                            Ok(AgentDelta::ToolResult { name, output, .. }) => {
                                yield Ok(ChatToken { tool_name: name, tool_output: output, tool_result: true, ..Default::default() });
                            }
                            Ok(AgentDelta::Done { stop_reason }) => {
                                if !ws_id.is_empty() {
                                    if !full.trim().is_empty() {
                                        let db3 = db.clone();
                                        let ws3 = ws_id.clone();
                                        let rn = role_name.clone();
                                        let body = full.clone();
                                        let _ = tokio::task::spawn_blocking(move || {
                                            db3.insert_agent_msg(&ws3, &rn, "assistant", &body, now_ms())
                                        }).await;
                                    }
                                    for (topic, summary) in parse_handoffs(&full) {
                                        if allowed_pub.is_empty() || allowed_pub.iter().any(|t| t == &topic) {
                                            let db2 = db.clone();
                                            let ws2 = ws_id.clone();
                                            let from = role_name.clone();
                                            let (t2, s2) = (topic.clone(), summary.clone());
                                            let _ = tokio::task::spawn_blocking(move || {
                                                db2.insert_event(&ws2, &from, &t2, &s2, now_ms())
                                            }).await;
                                            // Auto-react: fan out to subscribers.
                                            let lib = match &dispatch_ws_root {
                                                Some(root) => dispatch_roles.with_workspace(root),
                                                None => (*dispatch_roles).clone(),
                                            };
                                            dispatch_event(
                                                db.clone(), dispatch_providers.clone(), lib,
                                                ws_id.clone(), dispatch_ws_root.clone(),
                                                role_name.clone(), topic.clone(), summary.clone(),
                                            );
                                        }
                                    }
                                }
                                yield Ok(ChatToken { done: true, stop_reason, ..Default::default() });
                                return;
                            }
                            Err(e) => {
                                yield Ok(ChatToken { done: true, error: e.to_string(), ..Default::default() });
                                return;
                            }
                        }
                    }
                }
            }
        };
        Ok(Response::new(Box::pin(mapped) as Self::RoleChatStream))
    }

    async fn analyze_workspace(
        &self,
        req: Request<AnalyzeRequest>,
    ) -> Result<Response<PbAnalysis>, Status> {
        let r = req.into_inner();
        let provider_name = if r.provider.is_empty() { "anthropic".to_string() } else { r.provider };
        let model = if r.model.is_empty() {
            "claude-sonnet-4-6".to_string()
        } else {
            r.model
        };
        let provider = self
            .providers
            .get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;

        // Resolve workspace path.
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces
            .into_iter()
            .find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;

        let pm = atelier_pm::Pm::new(provider, model);
        let root = std::path::PathBuf::from(&ws.path);
        let analysis = pm
            .analyze(&root)
            .await
            .map_err(|e| Status::internal(format!("pm analyze: {e}")))?;

        Ok(Response::new(PbAnalysis {
            summary: analysis.summary,
            stack: analysis
                .stack
                .into_iter()
                .map(|t| PbStackTag { name: t.name, category: t.category })
                .collect(),
            team: analysis
                .team
                .into_iter()
                .map(|r| PbProposedRole {
                    name: r.name,
                    emoji: r.emoji,
                    why: r.why,
                    recommended_model: r.recommended_model,
                    tools: r.tools,
                    system_prompt: r.system_prompt,
                    recommended_provider: r.recommended_provider,
                    claude_skills: r.claude_skills,
                    publishes: r.publishes,
                    subscribes: r.subscribes,
                    cli_command: r.cli_command,
                    kickoff: r.kickoff,
                })
                .collect(),
        }))
    }

    async fn apply_team(
        &self,
        req: Request<ApplyTeamRequest>,
    ) -> Result<Response<ApplyTeamResponse>, Status> {
        let r = req.into_inner();
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-sonnet-4-6".into() } else { r.model };
        let provider = self
            .providers
            .get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;

        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces
            .into_iter()
            .find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;

        let pm = atelier_pm::Pm::new(provider, model);
        let root = std::path::PathBuf::from(&ws.path);
        let analysis = pm
            .analyze(&root)
            .await
            .map_err(|e| Status::internal(format!("pm analyze: {e}")))?;

        // Materialize each proposed role into <ws>/.atelier/roles/
        let roles_dir = root.join(".atelier").join("roles");
        purge_role_yamls(&roles_dir);
        std::fs::create_dir_all(&roles_dir)
            .map_err(|e| Status::internal(format!("mkdir {}: {e}", roles_dir.display())))?;

        let mut written = Vec::new();
        let mut local = (*self.roles).clone();
        for pr in &analysis.team {
            // Convert PM ProposedRole -> proto ProposedRole so we can reuse the helper.
            let pb_pr = PbProposedRole {
                name: pr.name.clone(),
                emoji: pr.emoji.clone(),
                why: pr.why.clone(),
                recommended_model: pr.recommended_model.clone(),
                tools: pr.tools.clone(),
                system_prompt: pr.system_prompt.clone(),
                recommended_provider: pr.recommended_provider.clone(),
                claude_skills: pr.claude_skills.clone(),
                publishes: pr.publishes.clone(),
                subscribes: pr.subscribes.clone(),
                cli_command: pr.cli_command.clone(),
                kickoff: pr.kickoff.clone(),
            };
            let role = role_from_proposed(&pb_pr, &roles_dir);
            let path = local
                .write_role(&roles_dir, &role)
                .map_err(|e| Status::internal(format!("write role: {e}")))?;
            written.push(path.to_string_lossy().into_owned());
        }

        Ok(Response::new(ApplyTeamResponse {
            analysis: Some(PbAnalysis {
                summary: analysis.summary,
                stack: analysis
                    .stack
                    .into_iter()
                    .map(|t| PbStackTag { name: t.name, category: t.category })
                    .collect(),
                team: analysis
                    .team
                    .into_iter()
                    .map(|r| PbProposedRole {
                        name: r.name,
                        emoji: r.emoji,
                        why: r.why,
                        recommended_model: r.recommended_model,
                        tools: r.tools,
                        system_prompt: r.system_prompt,
                        recommended_provider: r.recommended_provider,
                        claude_skills: r.claude_skills,
                        publishes: r.publishes,
                        subscribes: r.subscribes,
                        cli_command: r.cli_command,
                        kickoff: r.kickoff,
                    })
                    .collect(),
            }),
            written_paths: written,
        }))
    }

    async fn add_role(
        &self,
        req: Request<AddRoleRequest>,
    ) -> Result<Response<AddRoleResponse>, Status> {
        let r = req.into_inner();
        let pr = r.role.ok_or_else(|| Status::invalid_argument("role required"))?;
        if pr.name.trim().is_empty() {
            return Err(Status::invalid_argument("role.name required"));
        }
        // Resolve workspace path.
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await.unwrap().map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces.into_iter().find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;
        let roles_dir = std::path::PathBuf::from(&ws.path).join(".atelier").join("roles");
        std::fs::create_dir_all(&roles_dir)
            .map_err(|e| Status::internal(format!("mkdir: {e}")))?;
        let mut lib = (*self.roles).clone();
        let role = role_from_proposed(&pr, &roles_dir);
        let path = lib.write_role(&roles_dir, &role)
            .map_err(|e| Status::internal(format!("write role: {e}")))?;
        Ok(Response::new(AddRoleResponse {
            role: Some(PbRole {
                name: role.name.clone(),
                emoji: role.emoji.clone(),
                description: role.description.clone(),
                default_provider: role.default_provider.clone(),
                default_model: role.default_model.clone(),
                allowed_tools: role.allowed_tools.clone(),
                source_path: path.to_string_lossy().into_owned(),
                scope: "workspace".into(),
                claude_skills: role.claude_skills.clone(),
                handoff_publishes: role.handoff_topics.publishes.clone(),
                handoff_subscribes: role.handoff_topics.subscribes.clone(),
                cli_command: role.cli_command.clone(),
                kickoff: role.kickoff.clone(),
            }),
            written_path: path.to_string_lossy().into_owned(),
        }))
    }

    async fn delete_role(
        &self,
        req: Request<DeleteRoleRequest>,
    ) -> Result<Response<Empty>, Status> {
        let r = req.into_inner();
        let name = r.role_name.trim().to_string();
        if name.is_empty() {
            return Err(Status::invalid_argument("role_name required"));
        }
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let workspaces = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await.unwrap().map_err(|e| Status::internal(e.to_string()))?;
        let ws = workspaces.into_iter().find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found(format!("workspace '{ws_id}' not found")))?;
        let roles_dir = std::path::PathBuf::from(&ws.path).join(".atelier").join("roles");
        // Try both .yaml and .yml; ignore not-found.
        for ext in ["yaml", "yml"] {
            let p = roles_dir.join(format!("{name}.{ext}"));
            let _ = std::fs::remove_file(&p);
        }
        Ok(Response::new(Empty {}))
    }

    type TeamChatStream = TeamStream;

    async fn team_chat(
        &self,
        req: Request<TeamChatRequest>,
    ) -> Result<Response<Self::TeamChatStream>, Status> {
        let r = req.into_inner();
        let lib = self.effective_roles(&r.workspace_id).await?;

        // Resolve mentions: explicit list, else parse from message.
        let mentions: Vec<String> = if !r.mentions.is_empty() {
            r.mentions
        } else {
            let parsed = parse_mentions(&r.user_msg);
            if parsed.is_empty() {
                return Err(Status::invalid_argument(
                    "no @mentions in message and no explicit mentions list",
                ));
            }
            parsed
        };

        let providers = self.providers.clone();
        let model_override = r.model;
        let user_msg = r.user_msg.clone();

        // Resolve each role + provider up front so we can fail fast.
        struct Plan {
            role_name: String,
            provider: atelier_providers::DynProvider,
            request: ChatRequest,
        }
        let mut plans = Vec::new();
        for name in &mentions {
            let role = lib
                .get(name)
                .cloned()
                .ok_or_else(|| Status::not_found(format!("role '{name}' not found")))?;
            let model = if model_override.is_empty() {
                role.default_model.clone()
            } else {
                model_override.clone()
            };
            let provider = providers
                .get(&role.default_provider)
                .ok_or_else(|| Status::not_found(format!("provider '{}' not found", role.default_provider)))?;
            let req = ChatRequest {
                model,
                system: Some(role.system_prompt.clone()),
                messages: vec![ChatMessage { role: "user".into(), content: user_msg.clone() }],
                max_tokens: Some(1024),
            };
            plans.push(Plan { role_name: role.name.clone(), provider, request: req });
        }

        // Multiplex per-role streams into one tagged TeamChatEvent stream.
        let (tx, rx) =
            tokio::sync::mpsc::channel::<Result<TeamChatEvent, Status>>(128);

        for plan in plans {
            let tx = tx.clone();
            tokio::spawn(async move {
                let name = plan.role_name.clone();
                let inner = match plan.provider.chat(plan.request).await {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = tx
                            .send(Ok(TeamChatEvent {
                                role: name.clone(),
                                text: String::new(),
                                done: true,
                                stop_reason: String::new(),
                                error: e.to_string(),
                            }))
                            .await;
                        return;
                    }
                };
                let mut s = inner;
                while let Some(item) = s.next().await {
                    match item {
                        Ok(ChatDelta::Text(t)) => {
                            if tx
                                .send(Ok(TeamChatEvent {
                                    role: name.clone(),
                                    text: t,
                                    done: false,
                                    stop_reason: String::new(),
                                    error: String::new(),
                                }))
                                .await
                                .is_err()
                            { return; }
                        }
                        Ok(ChatDelta::Done { stop_reason }) => {
                            let _ = tx
                                .send(Ok(TeamChatEvent {
                                    role: name.clone(),
                                    text: String::new(),
                                    done: true,
                                    stop_reason,
                                    error: String::new(),
                                }))
                                .await;
                            return;
                        }
                        Err(e) => {
                            let _ = tx
                                .send(Ok(TeamChatEvent {
                                    role: name.clone(),
                                    text: String::new(),
                                    done: true,
                                    stop_reason: String::new(),
                                    error: e.to_string(),
                                }))
                                .await;
                            return;
                        }
                    }
                }
            });
        }
        drop(tx);

        let stream = tokio_stream::wrappers::ReceiverStream::new(rx);
        Ok(Response::new(Box::pin(stream) as Self::TeamChatStream))
    }

    async fn list_tools(
        &self,
        req: Request<ListToolsRequest>,
    ) -> Result<Response<ToolList>, Status> {
        let r = req.into_inner();
        let items: Vec<PbTool> = if r.role_name.is_empty() {
            self.tools
                .iter()
                .map(|t| PbTool {
                    name: t.name.clone(),
                    kind: t.kind.as_str().into(),
                    description: t.description.clone(),
                    needs_approval: t.needs_approval,
                })
                .collect()
        } else {
            let lib = self.effective_roles(&r.workspace_id).await?;
            let role = lib
                .get(&r.role_name)
                .cloned()
                .ok_or_else(|| Status::not_found(format!("role '{}' not found", r.role_name)))?;
            self.tools
                .intersect(&role.allowed_tools)
                .map(|t| PbTool {
                    name: t.name.clone(),
                    kind: t.kind.as_str().into(),
                    description: t.description.clone(),
                    needs_approval: t.needs_approval,
                })
                .collect()
        };
        Ok(Response::new(ToolList { items }))
    }

    async fn propose_project(
        &self,
        req: Request<ProposeProjectRequest>,
    ) -> Result<Response<PbProjectProposal>, Status> {
        let r = req.into_inner();
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-sonnet-4-6".into() } else { r.model };
        let provider = self
            .providers
            .get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;

        let pm = atelier_pm::Pm::new(provider, model);
        let proposal = pm
            .propose_from_idea(&r.idea)
            .await
            .map_err(|e| Status::internal(format!("pm propose: {e}")))?;

        Ok(Response::new(proposal_to_pb(proposal)))
    }

    async fn scaffold_project(
        &self,
        req: Request<ScaffoldProjectRequest>,
    ) -> Result<Response<ScaffoldProjectResponse>, Status> {
        let r = req.into_inner();
        let proposal = r
            .proposal
            .ok_or_else(|| Status::invalid_argument("missing proposal"))?;
        if proposal.project_slug.trim().is_empty() {
            return Err(Status::invalid_argument("proposal.project_slug required"));
        }
        let parent = std::path::PathBuf::from(&r.parent_dir);
        if !parent.is_dir() {
            return Err(Status::invalid_argument(format!(
                "parent_dir not a directory: {}",
                parent.display()
            )));
        }
        let project_dir = parent.join(&proposal.project_slug);
        std::fs::create_dir_all(&project_dir)
            .map_err(|e| Status::internal(format!("mkdir {}: {e}", project_dir.display())))?;

        // Drop a README so the folder isn't empty.
        let readme = project_dir.join("README.md");
        if !readme.exists() {
            let mut body = String::new();
            body.push_str(&format!("# {}\n\n", proposal.project_name));
            body.push_str(&format!("{}\n\n", proposal.summary));
            if !proposal.first_steps.is_empty() {
                body.push_str("## First steps\n\n");
                body.push_str(&proposal.first_steps);
                body.push('\n');
            }
            let _ = std::fs::write(&readme, body);
        }

        // Materialize roles.
        let roles_dir = project_dir.join(".atelier").join("roles");
        purge_role_yamls(&roles_dir);
        std::fs::create_dir_all(&roles_dir)
            .map_err(|e| Status::internal(format!("mkdir {}: {e}", roles_dir.display())))?;
        let mut local = (*self.roles).clone();
        let mut written = Vec::new();
        for pr in &proposal.team {
            let role = role_from_proposed(pr, &roles_dir);
            let path = local
                .write_role(&roles_dir, &role)
                .map_err(|e| Status::internal(format!("write role: {e}")))?;
            written.push(path.to_string_lossy().into_owned());
        }

        // Open as workspace.
        let db = self.db.clone();
        let project_str = project_dir.to_string_lossy().into_owned();
        let project_str_clone = project_str.clone();
        let existing = tokio::task::spawn_blocking(move || db.get_workspace_by_path(&project_str_clone))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let row = if let Some(mut r) = existing {
            r.opened_unix_ms = now_ms();
            let db = self.db.clone();
            let r2 = r.clone();
            tokio::task::spawn_blocking(move || db.upsert_workspace(&r2))
                .await
                .unwrap()
                .map_err(|e| Status::internal(e.to_string()))?;
            r
        } else {
            let row = atelier_core::db::WorkspaceRow {
                id: format!("ws_{}", uuid::Uuid::new_v4().simple()),
                path: project_str,
                name: proposal.project_name.clone(),
                opened_unix_ms: now_ms(),
            };
            let db = self.db.clone();
            let row_clone = row.clone();
            tokio::task::spawn_blocking(move || db.upsert_workspace(&row_clone))
                .await
                .unwrap()
                .map_err(|e| Status::internal(e.to_string()))?;
            row
        };

        Ok(Response::new(ScaffoldProjectResponse {
            workspace: Some(ws_to_pb(&row)),
            written_paths: written,
        }))
    }

    async fn publish_event(
        &self,
        req: Request<PublishEventRequest>,
    ) -> Result<Response<PbEvent>, Status> {
        let r = req.into_inner();
        let db = self.db.clone();
        let now = now_ms();
        let (ws, from, topic, summary) = (r.workspace_id, r.from_role, r.topic, r.summary);
        if topic.trim().is_empty() {
            return Err(Status::invalid_argument("topic required"));
        }
        let (ws2, from2, topic2, summary2) = (ws.clone(), from.clone(), topic.clone(), summary.clone());
        let db_ins = self.db.clone();
        let id = tokio::task::spawn_blocking(move || {
            db_ins.insert_event(&ws2, &from2, &topic2, &summary2, now)
        })
        .await
        .unwrap()
        .map_err(|e| Status::internal(e.to_string()))?;

        // Auto-react to subscribers.
        if !ws.is_empty() {
            let ws_root = {
                let dbq = self.db.clone();
                let wsq = ws.clone();
                let workspaces = tokio::task::spawn_blocking(move || dbq.list_workspaces())
                    .await.unwrap().unwrap_or_default();
                workspaces.into_iter().find(|w| w.id == ws).map(|w| std::path::PathBuf::from(w.path))
            };
            let lib = match &ws_root {
                Some(root) => self.roles.with_workspace(root),
                None => (*self.roles).clone(),
            };
            dispatch_event(
                self.db.clone(), self.providers.clone(), lib,
                ws.clone(), ws_root, from.clone(), topic.clone(), summary.clone(),
            );
        }

        Ok(Response::new(PbEvent {
            id,
            workspace_id: ws,
            from_role: from,
            topic,
            summary,
            created_unix_ms: now,
        }))
    }

    async fn list_events(
        &self,
        req: Request<ListEventsRequest>,
    ) -> Result<Response<EventList>, Status> {
        let r = req.into_inner();
        let limit = if r.limit > 0 { r.limit as usize } else { 50 };
        let db = self.db.clone();
        let (ws, topics, after) = (r.workspace_id, r.topics, r.after_id);
        let rows = tokio::task::spawn_blocking(move || db.list_events(&ws, &topics, after, limit))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(EventList {
            items: rows
                .into_iter()
                .map(|e| PbEvent {
                    id: e.id,
                    workspace_id: e.workspace_id,
                    from_role: e.from_role,
                    topic: e.topic,
                    summary: e.summary,
                    created_unix_ms: e.created_unix_ms,
                })
                .collect(),
        }))
    }

    async fn approve_tool(
        &self,
        req: Request<ApproveToolRequest>,
    ) -> Result<Response<Empty>, Status> {
        let r = req.into_inner();
        if let Some(tx) = self.approvals.lock().await.remove(&r.call_id) {
            let _ = tx.send(r.allow);
        }
        Ok(Response::new(Empty {}))
    }

    async fn get_history(
        &self,
        req: Request<GetHistoryRequest>,
    ) -> Result<Response<HistoryList>, Status> {
        let r = req.into_inner();
        let limit = if r.limit > 0 { r.limit as usize } else { 200 };
        let db = self.db.clone();
        let (ws, agent) = (r.workspace_id, r.agent_role);
        let rows = tokio::task::spawn_blocking(move || db.list_agent_history(&ws, &agent, limit))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(HistoryList {
            items: rows
                .into_iter()
                .map(|m| HistoryMessage {
                    role: m.role,
                    content: m.content,
                    created_unix_ms: m.created_unix_ms,
                })
                .collect(),
        }))
    }

    async fn search_workspace(
        &self,
        req: Request<SearchRequest>,
    ) -> Result<Response<SearchResults>, Status> {
        let r = req.into_inner();
        let k = if r.k > 0 { r.k as usize } else { 5 };
        let embedder = self.embedder().await?;
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let query = r.query.clone();

        let hits = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
            let indexer = Indexer::new(db, embedder);
            indexer.search(&ws_id, &query, k)
        })
        .await
        .map_err(|e| Status::internal(format!("join: {e}")))?
        .map_err(|e| Status::internal(format!("search: {e}")))?;

        Ok(Response::new(SearchResults {
            items: hits
                .into_iter()
                .map(|h| PbSearchHit {
                    path: h.path,
                    start_line: h.start_line,
                    end_line: h.end_line,
                    snippet: h.snippet,
                    score: h.score,
                })
                .collect(),
        }))
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "atelierd=info,tower=warn".into()),
        )
        .init();

    let args = Args::parse();
    let socket_path = args.socket.unwrap_or_else(default_socket_path);
    let data_dir = args.data_dir.unwrap_or_else(default_data_dir);
    let db_path = data_dir.join("atelier.db");

    let db = Db::open(&db_path).context("open db")?;
    info!(db = %db_path.display(), "db ready");

    if socket_path.exists() {
        // Probe: if something accepts on this socket, another daemon is alive.
        // We refuse rather than stomp.
        if probe_socket_alive(&socket_path) {
            anyhow::bail!(
                "another atelierd is already listening on {} — refusing to start",
                socket_path.display()
            );
        }
        std::fs::remove_file(&socket_path)
            .with_context(|| format!("removing stale socket {}", socket_path.display()))?;
    }
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let listener = UnixListener::bind(&socket_path)
        .with_context(|| format!("bind {}", socket_path.display()))?;
    let stream = UnixListenerStream::new(listener);

    info!(socket = %socket_path.display(), "atelierd listening");

    let roles = RoleLibrary::load_defaults();
    info!(count = roles.len(), "roles loaded");

    let svc = AtelierSvc {
        db: Arc::new(db),
        pty: Arc::new(PtyManager::new()),
        providers: Arc::new(ProviderRegistry::with_defaults()),
        embedder: Arc::new(OnceCell::new()),
        roles: Arc::new(roles),
        tools: Arc::new(ToolRegistry::with_defaults()),
        approvals: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        socket_path: socket_path.to_string_lossy().into_owned(),
    };

    if let Err(e) = Server::builder()
        .add_service(AtelierServer::new(svc))
        .serve_with_incoming(stream)
        .await
    {
        warn!(error = %e, "server exited");
    }

    Ok(())
}
