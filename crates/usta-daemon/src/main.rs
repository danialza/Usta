mod toolexec;

use anyhow::Context;
use usta_core::{
    db::{Db, TerminalRow, WorkspaceRow},
    default_data_dir, default_socket_path,
    pty::{PtyManager, TerminalSpec},
    tools::ToolRegistry,
};
use usta_proto::v1::{
    usta_server::{Usta, UstaServer},
    AnalyzeRequest, ApplyTeamRequest, ApplyTeamResponse, ChatRequest as PbChatReq, ChatToken,
    AddRoleRequest, AddRoleResponse, DeleteRoleRequest,
    CloseTerminalRequest, CloseWorkspaceRequest, CreateTerminalRequest, Empty, Event as PbEvent, EventList,
    GetHistoryRequest, HistoryList, HistoryMessage,
    IndexProgress as PbIndexProgress, IndexRequest, ListEventsRequest, ListRolesRequest,
    ListTerminalsRequest, ListToolsRequest, OpenWorkspaceRequest, PingRequest, PingResponse,
    ProjectProposal as PbProjectProposal, ProposeProjectRequest, ProposedRole as PbProposedRole,
    GrillQuestionsRequest, GrillQuestionsResponse, GrillQuestion as PbGrillQuestion,
    RefineProposalRequest,
    ApproveToolRequest, ProviderInfo, ProviderList, PtyClientMsg, PublishEventRequest,
    RegenerateKickoffRequest, RegenerateKickoffResponse,
    OrchestrateFeatureRequest, OrchestrateFeatureResponse, AffectedRole as PbAffectedRole,
    OrchestrateIssueRequest,
    RateLimitInfo,
    PtyServerMsg, Role as PbRole, RoleChatRequest, RoleList, ScaffoldProjectRequest,
    ScaffoldProjectResponse,
    SearchHit as PbSearchHit, SearchRequest, SearchResults, StackTag as PbStackTag,
    TeamChatEvent, TeamChatRequest, Terminal as PbTerminal, TerminalList, Tool as PbTool,
    ToolList, Workspace, WorkspaceAnalysis as PbAnalysis, WorkspaceList,
};
use usta_roles::{Role as RoleDef, RoleLibrary};
use usta_providers::{AgentDelta, ChatDelta, ChatMessage, ChatRequest, ProviderRegistry};
use usta_index::{Embedder, EmbedderConfig, Indexer};
use tokio::sync::OnceCell;
use clap::Parser;
use futures::StreamExt;
use std::{path::PathBuf, pin::Pin, sync::Arc};
use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{transport::Server, Request, Response, Status, Streaming};
use tracing::{error, info, warn};

#[derive(Parser, Debug)]
#[command(name = "ustad", version, about = "Usta daemon")]
struct Args {
    #[arg(long)]
    socket: Option<PathBuf>,
    /// Override data dir (DB lives here).
    #[arg(long)]
    data_dir: Option<PathBuf>,
}

struct UstaSvc {
    db: Arc<Db>,
    pty: Arc<PtyManager>,
    providers: Arc<ProviderRegistry>,
    embedder: Arc<OnceCell<Arc<Embedder>>>,
    roles: Arc<RoleLibrary>,
    tools: Arc<ToolRegistry>,
    approvals: Arc<tokio::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<bool>>>>,
    socket_path: String,
}

impl UstaSvc {
    /// Build a RoleLibrary view that includes builtin/user roles plus any
    /// workspace-scoped roles found under <ws>/.usta/roles/ when a
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

/// Background watcher: every 10s look for role-tagged terminals that have
/// been idle (no pty output for IDLE_SECS) AND whose last pty bytes contain
/// completion keywords (Done/Finished/Published/✓ etc) AND whose role has
/// unpublished handoff topics. Auto-publishes those topics with an
/// "auto-detected completion" summary so downstream roles unblock without
/// the user clicking "Mark done".
fn spawn_idle_watcher(
    db: Arc<Db>,
    roles: Arc<RoleLibrary>,
    _providers: Arc<ProviderRegistry>,
) {
    const POLL_SECS: u64 = 10;
    const IDLE_SECS: i64 = 60;          // bumped: 30s too eager
    const TAIL_BYTES: usize = 8192;     // bigger window for marker context
    // Strict markers: claude's bullet prefix (⏺ or `>`) followed by a strong
    // completion phrase OR explicit "Files Created/Modified" header. These
    // are structured output, not casual chatter. Loose words like " done"
    // alone caused false positives in welcome banners, narration, etc.
    let strong_markers: &[&str] = &[
        "⏺ done",
        "⏺ all done",
        "⏺ finished",
        "⏺ complete",
        "⏺ task complete",
        "⏺ published",
        "files created:",
        "files modified:",
        "event published:",
        "✓ done",
        "✅ done",
    ];
    // Mutual-exclusion pairs: passing/failing, cleared/finding — never
    // publish both for the same role on auto-detect.
    let exclusive_pairs: &[(&str, &str)] = &[
        ("tests.passing", "tests.failing"),
        ("security.cleared", "security.finding"),
        ("deploy.ready", "deploy.rolled_back"),
    ];
    tokio::spawn(async move {
        // De-dupe: don't republish same topic twice within a short window.
        let mut last_fired: std::collections::HashMap<(String, String), i64> =
            std::collections::HashMap::new();
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(POLL_SECS)).await;
            let now = now_ms();
            // List all known terminals (db source of truth).
            let dbq = db.clone();
            let terms = match tokio::task::spawn_blocking(move || dbq.list_terminals(None)).await {
                Ok(Ok(t)) => t, _ => continue,
            };
            for t in terms {
                if t.closed_unix_ms.is_some() { continue; }
                if t.role.is_empty() { continue; }
                // Idle check
                let dbq = db.clone();
                let tid = t.id.clone();
                let last = tokio::task::spawn_blocking(move || dbq.last_term_log_ms(&tid))
                    .await.ok().and_then(|r| r.ok()).flatten();
                let last_ms = match last { Some(v) => v, None => continue };
                // Read tail of pty log + check for completion keywords
                let dbq = db.clone();
                let tid = t.id.clone();
                let tail = tokio::task::spawn_blocking(move || dbq.read_term_log(&tid, TAIL_BYTES))
                    .await.ok().and_then(|r| r.ok()).unwrap_or_default();
                let tail_str = {
                    let raw = String::from_utf8_lossy(&tail).to_lowercase();
                    // Strip ANSI escape sequences (CSI / OSC / etc.) — they
                    // pollute extracted topic tokens with color codes like
                    // \x1b[38;5;153m so the pool filter fails to match yaml.
                    let mut out = String::with_capacity(raw.len());
                    let bytes = raw.as_bytes();
                    let mut i = 0;
                    while i < bytes.len() {
                        if bytes[i] == 0x1b {
                            i += 1;
                            if i < bytes.len() && bytes[i] == b'[' {
                                i += 1;
                                while i < bytes.len() && !(bytes[i] as char).is_ascii_alphabetic() { i += 1; }
                                if i < bytes.len() { i += 1; }
                            } else if i < bytes.len() && bytes[i] == b']' {
                                i += 1;
                                while i < bytes.len() && bytes[i] != 0x07 && bytes[i] != 0x1b { i += 1; }
                                if i < bytes.len() { i += 1; }
                            } else if i < bytes.len() {
                                i += 1;
                            }
                        } else {
                            out.push(bytes[i] as char);
                            i += 1;
                        }
                    }
                    out
                };
                // DETERMINISTIC SIGNAL (primary): the agent emits a structured
                // marker we defined — `[[handoff: <topic> | <summary>]]` — when
                // it finishes. This is a token WE control, not model prose, so
                // it's reliable regardless of phrasing/locale. Parse it first.
                let marker_topics: Vec<String> = parse_handoffs(&tail_str)
                    .into_iter().map(|(t, _)| t).collect();
                // Fast path: claude explicitly logged "Event <topic> published"
                // — accept after just 8s quiet (claude already announced done).
                let has_explicit_pub = tail_str.contains("event ")
                    && tail_str.contains("published");
                // A structured marker is as trustworthy as an explicit pub line
                // → short idle threshold either way.
                let has_strong_signal = has_explicit_pub || !marker_topics.is_empty();
                let idle_required = if has_strong_signal { 8 } else { 60 };
                if now - last_ms < idle_required * 1000 { continue; }
                let lower = tail_str;
                // Proceed to the detailed declared-topic check when we have a
                // strong signal, a keyword marker, OR the role has simply been
                // idle ≥60s. The latter lets CLIs that don't emit our marker
                // (codex / gemini / aider) still be detected via a bare topic
                // line — but only the candidate-pool below actually publishes,
                // and only if a declared topic literally appears + files changed.
                let idle_enough = now - last_ms >= 60 * 1000;
                let hit = has_strong_signal
                    || strong_markers.iter().any(|n| lower.contains(n))
                    || idle_enough;
                if !hit { continue; }
                // Resolve workspace + role first so we can compute blocker ts
                // before the file-change check (files written in a prior
                // terminal session still count as "fresh" relative to the
                // latest blocker event).
                let ws_root = {
                    let dbq = db.clone();
                    let wsq = t.workspace_id.clone();
                    let workspaces = tokio::task::spawn_blocking(move || dbq.list_workspaces())
                        .await.ok().and_then(|r| r.ok()).unwrap_or_default();
                    workspaces.into_iter().find(|w| w.id == wsq).map(|w| std::path::PathBuf::from(w.path))
                };
                let lib = match &ws_root {
                    Some(root) => roles.with_workspace(root),
                    None => (*roles).clone(),
                };
                let Some(role_def) = lib.get(&t.role).cloned() else { continue };
                if role_def.handoff_topics.publishes.is_empty() { continue; }
                // Which topics has this role already published?
                let dbq = db.clone();
                let wsq = t.workspace_id.clone();
                let mine_events = tokio::task::spawn_blocking(move || dbq.list_events(&wsq, &[], 0, 200))
                    .await.ok().and_then(|r| r.ok()).unwrap_or_default();
                // Latest blocker event (feature.requested, *.failing, *.finding,
                // *.rejected, *.rolled_back, *.broken, *.blocked) — any role's
                // publishes that PREDATE this need to fire again.
                let latest_blocker_ms = mine_events.iter()
                    .filter(|e| is_blocker_topic_or_feature(&e.topic))
                    .map(|e| e.created_unix_ms)
                    .max().unwrap_or(0);
                // Skip terminals that haven't logged anything since the
                // latest blocker — they're stale and can't have valid
                // completion claims for this round.
                if latest_blocker_ms > 0 && last_ms < latest_blocker_ms {
                    continue;
                }
                // Real-work check: count files written after the LATEST
                // blocker for this workspace (or terminal launch — whichever
                // is later). Lets resumed sessions credit prior writes.
                // Use blocker timestamp when present (work in prior terminal
                // sessions still counts); fall back to terminal launch.
                let since_ms = if latest_blocker_ms > 0 { latest_blocker_ms } else { t.created_unix_ms };
                let recent_files = ws_root.as_ref()
                    .map(|r| collect_changed_files_since(r, since_ms))
                    .unwrap_or_default();
                // NOTE: the file-change requirement is enforced LATER and ONLY
                // for the weak keyword path. An explicit topic signal (our
                // marker, a bare topic line, or "Event X published") is trusted
                // even with no new files — agents often verify existing work
                // without rewriting it (idempotent rerun) yet still finished.
                // (Detailed "candidate" log moved below — only emit when we
                // actually have an unpublished topic to fire, so a role that
                // already published doesn't spam the log every 10s tick.)
                let mine_topics: std::collections::HashSet<String> = mine_events.iter()
                    .filter(|e| e.from_role == role_def.name && e.created_unix_ms > latest_blocker_ms)
                    .map(|e| e.topic.clone()).collect();
                // Trust EXPLICIT announcements: parse pty for lines like
                // "Event <topic> published" and publish only those topics
                // (intersected with the role's declared handoffPublishes for
                // safety). This avoids publishing topics the role has in its
                // yaml by hallucination but never actually claimed.
                let explicit_topics: Vec<String> = {
                    let pat = "event ";
                    let mut out: Vec<String> = Vec::new();
                    let mut search = lower.as_str();
                    while let Some(idx) = search.find(pat) {
                        let after = &search[idx + pat.len()..];
                        // Take chars until whitespace; token must contain '.'
                        let token: String = after.chars()
                            .take_while(|c| !c.is_whitespace() && *c != ':' && *c != ',' && *c != '!')
                            .collect();
                        let token_len = token.len();
                        if token.contains('.') {
                            // Confirm it's followed (loosely) by "published"
                            let rest = &after[token_len..];
                            if rest.contains("published") && !out.contains(&token) {
                                out.push(token);
                            }
                        }
                        // advance past this hit
                        search = &after[token_len.max(1)..];
                    }
                    out
                };
                // Topic source priority:
                //   1. structured [[handoff: …]] markers — deterministic
                //   2. "Event <topic> published" prose — explicit but loose
                //   3. declared publishes — only if a strong keyword marker hit
                // Each is intersected with the role's declared publishes so a
                // hallucinated topic never escapes onto the bus.
                let declared_ok = |t: &String| {
                    let t = t.to_lowercase();
                    role_def.handoff_topics.publishes.iter().any(|p| {
                        let p = p.to_lowercase();
                        p == t || p.ends_with(&t) || t.ends_with(&p)
                    })
                };
                // Bare topic on its own line: CLIs that don't speak our marker
                // (codex / gemini / aider) often just print the topic name when
                // done (the kickoff says "Publish logic.ready when done"). Match
                // ONLY a line whose trimmed content equals a declared topic — so
                // the instruction echo "Publish logic.ready when done" does NOT
                // match, but the agent's final standalone "logic.ready" does.
                let bare_topics: Vec<String> = role_def.handoff_topics.publishes.iter()
                    .filter(|t| {
                        let tl = t.to_lowercase();
                        lower.lines().any(|ln| ln.trim() == tl)
                    })
                    .cloned().collect();
                // Explicit topic signals (trusted without file changes):
                let explicit_pool: Vec<String> = if !marker_topics.is_empty() {
                    marker_topics.into_iter().filter(|t| declared_ok(t)).collect()
                } else if !explicit_topics.is_empty() {
                    explicit_topics.into_iter().filter(|t| declared_ok(t)).collect()
                } else if !bare_topics.is_empty() {
                    bare_topics
                } else {
                    Vec::new()
                };
                let candidate_pool: Vec<String> = if !explicit_pool.is_empty() {
                    explicit_pool
                } else if strong_markers.iter().any(|n| lower.contains(n)) && !recent_files.is_empty() {
                    // Weak keyword path: only trust it if the role actually
                    // wrote files since the blocker (guards against narration).
                    role_def.handoff_topics.publishes.clone()
                } else {
                    Vec::new()
                };
                let mut unpub: Vec<String> = candidate_pool.into_iter()
                    .filter(|t| !mine_topics.contains(t))
                    .collect();
                if unpub.is_empty() { continue; }
                // Resolve mutual-exclusion pairs: pick at most one based on
                // which appears LATER in the pty tail (more recent claim).
                for (a, b) in exclusive_pairs {
                    let has_a = unpub.iter().any(|t| t == a);
                    let has_b = unpub.iter().any(|t| t == b);
                    if has_a && has_b {
                        let pos_a = lower.rfind(a);
                        let pos_b = lower.rfind(b);
                        let keep = match (pos_a, pos_b) {
                            (Some(pa), Some(pb)) => if pa > pb { *a } else { *b },
                            (Some(_), None)      => *a,
                            (None, Some(_))      => *b,
                            (None, None)         => *a,  // arbitrary
                        };
                        unpub.retain(|t| t == keep || (t != a && t != b));
                    }
                }
                // De-dupe per topic (skip if fired in last 5 min)
                unpub.retain(|topic| {
                    let key = (t.id.clone(), topic.clone());
                    let prev = last_fired.get(&key).copied().unwrap_or(0);
                    if now - prev < 5 * 60 * 1000 { return false; }
                    last_fired.insert(key, now);
                    true
                });
                if unpub.is_empty() { continue; }
                tracing::info!(role = %t.role, files = recent_files.len(), topics = ?unpub,
                               "idle-watcher: completion detected → publishing");
                let files = ws_root.as_ref().map(|r| collect_changed_files(r)).unwrap_or_default();
                for topic in unpub {
                    let summary = format!("auto-detected completion (idle {}s + keyword in pty tail)", (now - last_ms) / 1000);
                    let dbq = db.clone();
                    let wsq = t.workspace_id.clone();
                    let from = role_def.name.clone();
                    let topic_c = topic.clone();
                    let summary_c = summary.clone();
                    let files_c = files.clone();
                    let _ = tokio::task::spawn_blocking(move || {
                        dbq.insert_event(&wsq, &from, &topic_c, &summary_c, now, &files_c)
                    }).await;
                    tracing::info!(role = %role_def.name, topic = %topic, "idle-watcher: auto-published");
                    // Fan out to subscribers headless.
                    dispatch_event(
                        db.clone(), _providers.clone(), lib.clone(),
                        t.workspace_id.clone(), ws_root.clone(),
                        role_def.name.clone(), topic, summary,
                    );
                }
            }
        }
    });
}

/// Same as `collect_changed_files` but uses `since_ms` as the mtime cutoff
/// instead of "last 5 minutes". Use the terminal's `created_unix_ms` so the
/// watcher sees every file the role wrote since it launched, regardless of
/// how long the session took.
fn collect_changed_files_since(root: &std::path::Path, since_ms: i64) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let git_dir = root.join(".git");
    if git_dir.is_dir() {
        // git is timestamp-agnostic — return current dirty set; caller
        // doesn't strictly need the since_ms when git is available.
        let output = std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .current_dir(root)
            .output();
        if let Ok(o) = output {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                let trimmed = line.get(3..).unwrap_or("");
                let path = trimmed.split(" -> ").last().unwrap_or(trimmed).trim();
                if !path.is_empty() && out.len() < 40 {
                    out.push(path.to_string());
                }
            }
            return out;
        }
    }
    // mtime walk, cutoff = since_ms (terminal launch time)
    fn walk(dir: &std::path::Path, root: &std::path::Path, cutoff_ms: i64, out: &mut Vec<String>, depth: u32) {
        if depth > 4 || out.len() >= 40 { return; }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let s = name.to_string_lossy();
            if s.starts_with('.') || s == "node_modules" || s == "target" || s == ".build" { continue; }
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                walk(&path, root, cutoff_ms, out, depth + 1);
            } else if let Ok(mt) = meta.modified() {
                let mt_ms = mt.duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64).unwrap_or(0);
                if mt_ms >= cutoff_ms {
                    if let Ok(rel) = path.strip_prefix(root) {
                        out.push(rel.to_string_lossy().to_string());
                    }
                }
            }
            if out.len() >= 40 { return; }
        }
    }
    walk(root, root, since_ms, &mut out, 0);
    out
}

/// Best-effort list of files changed in `root` "recently".
/// 1) If `.git` dir: run `git status --porcelain` and parse paths.
/// 2) Else: walk `root` for files modified in the last 5 minutes.
fn collect_changed_files(root: &std::path::Path) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let git_dir = root.join(".git");
    if git_dir.is_dir() {
        let output = std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .current_dir(root)
            .output();
        if let Ok(o) = output {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                // Format: "XY path"  or "XY path -> newpath"
                let trimmed = line.get(3..).unwrap_or("");
                let path = trimmed.split(" -> ").last().unwrap_or(trimmed).trim();
                if !path.is_empty() && out.len() < 40 {
                    out.push(path.to_string());
                }
            }
            return out;
        }
    }
    // Fallback: mtime walk (max depth 4, last 5 min).
    let cutoff_ms = now_ms() - 5 * 60 * 1000;
    fn walk(dir: &std::path::Path, root: &std::path::Path, cutoff_ms: i64, out: &mut Vec<String>, depth: u32) {
        if depth > 4 || out.len() >= 40 { return; }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let s = name.to_string_lossy();
            if s.starts_with('.') || s == "node_modules" || s == "target" || s == ".build" { continue; }
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                walk(&path, root, cutoff_ms, out, depth + 1);
            } else if let Ok(mt) = meta.modified() {
                let mt_ms = mt.duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64).unwrap_or(0);
                if mt_ms >= cutoff_ms {
                    if let Ok(rel) = path.strip_prefix(root) {
                        out.push(rel.to_string_lossy().to_string());
                    }
                }
            }
            if out.len() >= 40 { return; }
        }
    }
    walk(root, root, cutoff_ms, &mut out, 0);
    out
}

/// Fan an event out to every workspace role that subscribes to its topic
/// (except the publisher), running each as a headless agentic turn. Headless
/// turns may read but not write/shell (no human to approve), and their own
/// handoffs are recorded WITHOUT re-dispatching, to prevent storms.
/// Topics that signal a downstream role flagged a blocker — should auto-fire
/// OrchestrateIssue so PM writes fix-tasks for upstream owners.
fn is_blocker_topic(topic: &str) -> bool {
    let t = topic.to_lowercase();
    if t == "feature.requested" { return false; }  // feature triggers separately
    let suffixes = [".failing", ".failed", ".finding", ".rejected",
                    ".rolled_back", ".broken", ".blocked"];
    suffixes.iter().any(|s| t.ends_with(s))
}

/// Includes feature.requested for "reopens roles" detection.
fn is_blocker_topic_or_feature(topic: &str) -> bool {
    topic == "feature.requested" || is_blocker_topic(topic)
}

/// Spawn an OrchestrateIssue call in the background so the caller's
/// publish_event RPC returns immediately. PM writes fix-tasks into the
/// affected roles' yamls; UI picks them up on next role-list refresh.
fn spawn_auto_orchestrate_issue(
    db: Arc<usta_core::db::Db>,
    providers: Arc<ProviderRegistry>,
    lib: RoleLibrary,
    workspace_id: String,
    workspace_root: Option<std::path::PathBuf>,
    from_role: String,
    topic: String,
    summary: String,
) {
    tokio::spawn(async move {
        // Build team yaml blob (workspace roles only)
        let mut team_yaml = String::new();
        for r in lib.iter() {
            if r.scope != usta_roles::RoleScope::Workspace { continue; }
            if let Ok(s) = serde_yaml::to_string(r) {
                team_yaml.push_str(&format!("---\n{s}"));
            }
        }
        // Event log
        let dbq = db.clone();
        let wsq = workspace_id.clone();
        let events = match tokio::task::spawn_blocking(move || dbq.list_events(&wsq, &[], 0, 200)).await {
            Ok(Ok(e)) => e, _ => return,
        };
        let event_log = events.iter()
            .map(|e| format!("@{} -> {}: {}", e.from_role, e.topic, e.summary))
            .collect::<Vec<_>>().join("\n");
        // Default PM provider
        let Some(provider) = providers.get("anthropic") else { return };
        let pm = usta_pm::Pm::new(provider, "claude-haiku-4-5-20251001".to_string());
        match pm.orchestrate_issue(&team_yaml, &event_log, &from_role, &topic, &summary).await {
            Ok((plan_summary, plan)) => {
                tracing::info!(topic = %topic, roles = plan.len(),
                    "auto-orchestrate-issue: {plan_summary}");
                for (role_name, task) in &plan {
                    if let Some(role) = lib.get(role_name) {
                        let mut updated = role.clone();
                        updated.kickoff = task.clone();
                        if let Ok(yaml) = serde_yaml::to_string(&updated) {
                            let _ = std::fs::write(&updated.source, yaml);
                        }
                    }
                }
                // Publish a meta event so UI can toast
                let summary_msg = format!("Issue plan ready ({} role(s)): {}",
                    plan.len(),
                    plan.iter().map(|(n,_)| format!("@{n}")).collect::<Vec<_>>().join(", "));
                let _ = db.insert_event(&workspace_id, "pm", "issue.plan.ready",
                    &summary_msg, now_ms(), &[]);
            }
            Err(e) => {
                tracing::warn!(topic = %topic, error = %e, "auto-orchestrate-issue failed");
            }
        }
        let _ = workspace_root;
    });
}

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
        // Case-insensitive exact match. With graph-repaired teams (topics
        // normalized at build), producer and consumer strings are identical,
        // so this lines the headless fan-out up with what the UI shows ready.
        let topic_lc = topic.to_lowercase();
        if !role.handoff_topics.subscribes.iter().any(|t| t.to_lowercase() == topic_lc) {
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
    provider: usta_providers::DynProvider,
    role: RoleDef,
    ws_id: String,
    ws_root: Option<std::path::PathBuf>,
    from_role: String,
    topic: String,
    summary: String,
) {
    let auto = role.autonomy.eq_ignore_ascii_case("auto");
    let user_msg = if auto {
        format!(
            "Team update from @{from_role} [{topic}]: {summary}\n\n\
             If this affects your area, DO the work now — you may read, write \
             files, and run shell. When you finish something the team needs, \
             end with [[handoff: <topic> | <summary>]]. If not relevant, reply 'noted'."
        )
    } else {
        format!(
            "Team update from @{from_role} [{topic}]: {summary}\n\n\
             If this affects your area, take the necessary action now (you may read \
             files; writes/shell need a human, so describe them). If not relevant, \
             reply 'noted'."
        )
    };

    let mut system = role.system_prompt.clone();
    system.push_str(&usta_core::skills::render_block(&role.claude_skills));
    if !role.handoff_topics.publishes.is_empty() {
        system.push_str(&format!(
            "\n\n## Handoffs\nIf you complete something the team needs, end with:\n\
             [[handoff: <topic> | <summary>]]\nYour topics: {}\n",
            role.handoff_topics.publishes.join(", ")
        ));
    }

    // Tools for headless turns. In "manual" autonomy only Allowed (read-only)
    // tools run; "auto" roles also run Ask-gated tools (write/exec) without a
    // human — the trade is power vs. safety, opt-in per role.
    let tools = ws_root.as_ref().map(|_| toolexec::specs_for_role(&role)).unwrap_or_default();
    let exec_root = ws_root.clone();
    let exec_role = role.clone();
    let exec: usta_providers::ToolExec = std::sync::Arc::new(move |name, input| {
        let root = exec_root.clone();
        let role = exec_role.clone();
        let auto = auto;
        Box::pin(async move {
            let Some(root) = root else { return Err(anyhow::anyhow!("no workspace")) };
            match toolexec::gate(&role, &name) {
                toolexec::Gate::Allowed => toolexec::execute(root, role, name, input).await,
                toolexec::Gate::Ask if auto => toolexec::execute(root, role, name, input).await,
                toolexec::Gate::Denied => Ok(format!("⛔ {name} denied by role policy")),
                _ => Ok(format!("⏸ {name} skipped (headless manual role needs a human to approve)")),
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
                db3.insert_event(&ws3, &rn3, &t, &s, now_ms(), &[])
            }).await;
        }
    }
}

/// Locate the usta-mcp binary (sibling of this daemon's executable).
fn usta_mcp_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let cand = dir.join("usta-mcp");
    if cand.exists() { Some(cand) } else { None }
}

/// Write a project .mcp.json registering the Usta bus server, so
/// MCP-capable CLI agents (Claude Code) can publish/subscribe events.
/// Skips if a .mcp.json already exists (don't clobber user config).
fn write_mcp_config(cwd: &str) {
    let Some(mcp) = usta_mcp_path() else { return };
    let path = std::path::Path::new(cwd).join(".mcp.json");
    if path.exists() { return; }
    let cfg = serde_json::json!({
        "mcpServers": {
            "usta": { "command": mcp.to_string_lossy() }
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
        "You are the @{name} specialist on the Usta team working in {ws}.\n\n",
        name = role.name,
        ws = workspace_path
    ));

    // HARD RULE up top so claude can't miss it. Without publish_event, the
    // event bus has no idea the role finished and the whole orchestration
    // chain stalls. The rule must come BEFORE the role's system prompt so
    // it's the first thing claude reads.
    let pubs_csv = role.handoff_topics.publishes.join(", ");
    out.push_str(&format!(
        "## ⚠ HARD RULE — ALWAYS PUBLISH WHEN DONE\n\
         The MOMENT you finish a milestone or deliver an artifact, your\n\
         IMMEDIATE next action MUST be to call the MCP tool\n\
         `mcp__usta__publish_event(topic, summary)` — exactly ONE call\n\
         per topic you completed. This is NOT optional.\n\n\
         Your topics: [{pubs}]\n\
         Pick the matching topic from that list. The summary is 1-2\n\
         sentences naming the artifact + main outcome.\n\n\
         If you skip publish_event, downstream roles (qa, security, devops)\n\
         never get notified, the bus stays stale, the user is blocked. The\n\
         orchestrator literally cannot detect 'done' any other way.\n\n\
         WRONG: write a report and stop. Usta never marks you done.\n\
         RIGHT: write report → call publish_event → THEN you may end the turn.\n\n\
         DETERMINISTIC FALLBACK: on the FINAL line of your turn, print one\n\
         marker per finished topic, EXACTLY in this format (the orchestrator\n\
         parses it literally, so do not paraphrase):\n\
             [[handoff: <topic> | <one-line summary>]]\n\
         Example: [[handoff: api.ready | REST endpoints for auth + products done]]\n\
         This guarantees the bus learns you finished even if the MCP call drops.\n\n",
        pubs = pubs_csv
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
        "\n## Usta MCP tools (you are connected to the team event bus)\n\
         - publish_event(topic, summary): announce when you finish a milestone.\n\
         - list_events(topics?, limit?): see recent team activity.\n\
         - wait_for_event(topics, timeout_seconds?): block until upstream work lands.\n\
         REPEAT: publish_event is MANDATORY when you complete anything. See HARD RULE above.\n",
    );
    // Universal skills: every role gets these regardless of yaml, so the
    // whole team always has memory recall + interview-first + TDD + diagnose
    // + refactor + PRD/issues helpers. Yaml-specific skills append after.
    let universal: &[&str] = &[
        "memory-recall", "grill-me", "tdd", "diagnose",
        "improve-codebase-architecture", "to-prd", "to-issues",
    ];
    let mut all_skills: Vec<String> = universal.iter().map(|s| s.to_string()).collect();
    for s in &role.claude_skills {
        if !all_skills.contains(s) { all_skills.push(s.clone()); }
    }
    out.push_str(&format!(
        "\n## Claude skills available (use any time)\n{}\n",
        all_skills.iter().map(|s| format!("- {s}")).collect::<Vec<_>>().join("\n")
    ));
    // Caveman terse-mode: every claude pane shares one team voice — short,
    // technical, no filler. Cuts tokens ~75% across the whole project.
    out.push_str(
        "\n## Voice (CAVEMAN MODE — ALWAYS ON)\n\
         Respond terse like a smart caveman. Drop articles (a/an/the), \
         filler (just/really/basically), pleasantries (sure/of course), \
         hedging. Fragments OK. Short synonyms (big not extensive, fix \
         not 'implement a solution for'). Technical terms exact. Code \
         blocks unchanged. Errors quoted exact. Pattern: '[thing] \
         [action] [reason]. [next step].' One paragraph max unless \
         multi-step sequence where order matters. Stay caveman every \
         response, every turn — no drift back to verbose mode.\n",
    );
    // Memory: before reasoning, recall prior decisions; after any \
    // meaningful change, consolidate notes for future sessions.
    out.push_str(
        "\n## Memory (ALWAYS ON)\n\
         On the FIRST turn of every session, silently consider what you \
         previously decided / learned on this project (file layout, naming \
         conventions, prior bug-fixes, design constraints). Pull from \
         CLAUDE.md, .usta/memory.md, README.md, recent git log. After \
         shipping a non-trivial change, append a one-line note to \
         .usta/memory.md under a `## <role>` heading — date, what \
         changed, why. Keep notes short; future-you will thank you.\n",
    );
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

fn pb_proposal_to_pm(p: &PbProjectProposal) -> usta_pm::ProjectProposal {
    usta_pm::ProjectProposal {
        project_name: p.project_name.clone(),
        project_slug: p.project_slug.clone(),
        summary: p.summary.clone(),
        first_steps: p.first_steps.clone(),
        stack: p.stack.iter().map(|t| usta_pm::StackTag {
            name: t.name.clone(), category: t.category.clone(),
        }).collect(),
        team: p.team.iter().map(|r| usta_pm::ProposedRole {
            name: r.name.clone(),
            emoji: r.emoji.clone(),
            why: r.why.clone(),
            recommended_provider: r.recommended_provider.clone(),
            recommended_model: r.recommended_model.clone(),
            tools: r.tools.clone(),
            claude_skills: r.claude_skills.clone(),
            publishes: r.publishes.clone(),
            subscribes: r.subscribes.clone(),
            system_prompt: r.system_prompt.clone(),
            cli_command: r.cli_command.clone(),
            kickoff: r.kickoff.clone(),
        }).collect(),
    }
}

fn proposal_to_pb(p: usta_pm::ProjectProposal) -> PbProjectProposal {
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
        handoff_topics: usta_roles::HandoffTopics {
            publishes: pr.publishes.clone(),
            subscribes: pr.subscribes.clone(),
        },
        cli_command: pr.cli_command.clone(),
        kickoff: pr.kickoff.clone(),
        autonomy: "manual".into(),
        source: roles_dir.join(format!("{}.yaml", pr.name)),
        scope: usta_roles::RoleScope::Workspace,
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
        role: t.role.clone(),
    }
}

#[tonic::async_trait]
impl Usta for UstaSvc {
    async fn ping(&self, req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        let client = req.into_inner().client_name;
        Ok(Response::new(PingResponse {
            daemon_version: usta_core::DAEMON_VERSION.into(),
            server_unix_ms: now_ms(),
            greeting: format!("hi {client}, ustad here"),
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
            extra_env.push(("USTA_SOCKET".into(), self.socket_path.clone()));
            extra_env.push(("USTA_WORKSPACE_ID".into(), workspace.id.clone()));
            if !r.role.is_empty() {
                extra_env.push(("USTA_ROLE".into(), r.role.clone()));
            }
            // Write a project .mcp.json so MCP-capable CLIs (Claude Code) load
            // the Usta bus server. Points at the usta-mcp sibling binary.
            write_mcp_config(&cwd);
            // Allow MCP servers from this project without prompting.
            write_claude_settings(&cwd);

            // For claude (Claude Code) launches with a role: write a per-role
            // brief and append it to the system prompt so the CLI knows who it
            // is, what it owns, and how to use the Usta bus.
            if !r.role.is_empty() && effective_command.trim_start().starts_with("claude") {
                let lib = self.roles.with_workspace(std::path::Path::new(&workspace.path));
                if let Some(role) = lib.get(&r.role) {
                    let brief = render_role_brief(role, &workspace.path);
                    let rel_brief =
                        format!(".usta/agents/{}.md", sanitize_role_name(&r.role));
                    let abs_brief = std::path::PathBuf::from(&workspace.path).join(&rel_brief);
                    if let Some(parent) = abs_brief.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    let _ = std::fs::write(&abs_brief, brief);
                    // Rewrite: `claude [args]` -> `unset *_KEY; claude --append-system-prompt "$(cat .usta/agents/<role>.md)" [args]`
                    // Unset prevents "auth conflict" warning when user has
                    // ANTHROPIC_API_KEY exported in shell rc — Pro/Max token
                    // from claude.ai login should win for CLI sessions.
                    let trimmed = effective_command.trim_start();
                    let (head, tail) = trimmed.split_once(char::is_whitespace).unwrap_or((trimmed, ""));
                    // If this role had a prior terminal in this workspace, add
                    // --continue so claude resumes its last session (real memory)
                    // instead of starting cold. First launch omits it.
                    let cont = {
                        let dbq = self.db.clone();
                        let wsq = workspace.id.clone();
                        let roleq = r.role.clone();
                        let prev = tokio::task::spawn_blocking(move || dbq.previous_terminal_id(&wsq, &roleq))
                            .await.ok().and_then(|x| x.ok()).flatten();
                        // Only use --continue when BOTH our DB has a prior
                        // term AND claude actually has a session file for
                        // this cwd. Otherwise claude prints "No conversation
                        // found to continue" and dies before any prompt.
                        // Claude stores sessions at:
                        //   ~/.claude/projects/<cwd-escaped>/<uuid>.jsonl
                        // Path escape = replace each `/` with `-`.
                        let has_session = if prev.is_some() {
                            let encoded = workspace.path.replace('/', "-");
                            let home = std::env::var("HOME").unwrap_or_default();
                            let dir = std::path::PathBuf::from(home)
                                .join(".claude").join("projects").join(&encoded);
                            std::fs::read_dir(&dir).map(|rd|
                                rd.filter_map(|e| e.ok()).any(|e|
                                    e.path().extension().map(|x| x == "jsonl").unwrap_or(false))
                            ).unwrap_or(false)
                        } else { false };
                        if has_session { " --continue" } else { "" }
                    };
                    effective_command = format!(
                        "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; {head}{cont} --append-system-prompt \"$(cat {rel})\" {tail}",
                        head = head,
                        cont = cont,
                        rel = rel_brief,
                        tail = tail
                    );
                }
            }
            // Codex reads ~/.codex/config.toml [mcp_servers], NOT .mcp.json.
            // Inject the Usta bus server at launch via a -c override so codex
            // panes get the publish_event tool too. It inherits USTA_* env
            // (set above), so usta-mcp connects to this exact workspace/role.
            // (No global config file is touched.)
            if effective_command.trim_start().starts_with("codex") {
                if let Some(mcp) = usta_mcp_path() {
                    let trimmed = effective_command.trim_start();
                    let (head, tail) = trimmed.split_once(char::is_whitespace).unwrap_or((trimmed, ""));
                    effective_command = format!(
                        "{head} -c 'mcp_servers.usta.command=\"{mcp}\"' {tail}",
                        head = head,
                        mcp = mcp.to_string_lossy(),
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
        let term_arc = self.pty
            .create(spec)
            .await
            .map_err(|e| Status::internal(format!("pty create: {e}")))?;

        // Preload scrollback from any previous (workspace, role) terminal so
        // the new session opens with prior history visible above its fresh prompt.
        if !r.role.is_empty() {
            let dbq = self.db.clone();
            let wsq = workspace.id.clone();
            let roleq = r.role.clone();
            if let Ok(prev) = tokio::task::spawn_blocking(move || dbq.previous_terminal_id(&wsq, &roleq)).await {
                if let Ok(Some(prev_id)) = prev {
                    let dbr = self.db.clone();
                    let prev_id_clone = prev_id.clone();
                    if let Ok(blob) = tokio::task::spawn_blocking(move || dbr.read_term_log(&prev_id_clone, 256 * 1024)).await {
                        if let Ok(bytes) = blob {
                            if !bytes.is_empty() {
                                let banner = b"\r\n\x1b[33m--- Prior session (replayed from DB) ---\x1b[0m\r\n";
                                let mut payload = Vec::with_capacity(banner.len() + bytes.len() + 64);
                                payload.extend_from_slice(banner);
                                payload.extend_from_slice(&bytes);
                                payload.extend_from_slice(b"\r\n\x1b[33m--- End of replay; fresh session below ---\x1b[0m\r\n");
                                term_arc.prepend_scrollback(&payload);
                            }
                        }
                    }
                }
            }
        }

        // Mirror pty output → DB for future restart replay (batched ~512ms).
        {
            let mut rx = term_arc.subscribe();
            let dbm = self.db.clone();
            let tid = id.clone();
            tokio::spawn(async move {
                let mut buf: Vec<u8> = Vec::with_capacity(8192);
                let mut last_flush = std::time::Instant::now();
                loop {
                    tokio::select! {
                        msg = rx.recv() => {
                            match msg {
                                Ok(bytes) => {
                                    buf.extend_from_slice(&bytes);
                                    if buf.len() >= 64 * 1024 || last_flush.elapsed() >= std::time::Duration::from_millis(500) {
                                        let to_write = std::mem::take(&mut buf);
                                        let dbf = dbm.clone();
                                        let tidf = tid.clone();
                                        let _ = tokio::task::spawn_blocking(move || dbf.append_term_log(&tidf, &to_write, now_ms())).await;
                                        last_flush = std::time::Instant::now();
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        _ = tokio::time::sleep(std::time::Duration::from_millis(750)) => {
                            if !buf.is_empty() {
                                let to_write = std::mem::take(&mut buf);
                                let dbf = dbm.clone();
                                let tidf = tid.clone();
                                let _ = tokio::task::spawn_blocking(move || dbf.append_term_log(&tidf, &to_write, now_ms())).await;
                                last_flush = std::time::Instant::now();
                            }
                        }
                    }
                }
                if !buf.is_empty() {
                    let dbf = dbm.clone();
                    let tidf = tid.clone();
                    let _ = tokio::task::spawn_blocking(move || dbf.append_term_log(&tidf, &buf, now_ms())).await;
                }
            });
        }

        let created = now_ms();
        let row = TerminalRow {
            id: id.clone(),
            workspace_id: workspace.id.clone(),
            shell,
            cwd,
            created_unix_ms: created,
            closed_unix_ms: None,
            role: r.role.clone(),
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
        use usta_proto::v1::pty_client_msg::Kind as CK;
        use usta_proto::v1::pty_server_msg::Kind as SK;
        use usta_proto::v1::{PtyError, PtyExit, PtyOutput};

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
        // Snapshot scrollback BEFORE we let live bytes flow — replay first.
        let replay = term.scrollback();
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
            // Replay scrollback first (one big frame) so reattach shows
            // pty history (pending prompts, prior output).
            if !replay.is_empty() {
                yield Ok(PtyServerMsg {
                    kind: Some(SK::Output(PtyOutput { data: replay })),
                });
            }
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
            && lib.iter().any(|r| matches!(r.scope, usta_roles::RoleScope::Workspace));
        let items = lib
            .iter()
            .filter(|r| !has_ws_roles || matches!(r.scope, usta_roles::RoleScope::Workspace))
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
        system.push_str(&usta_core::skills::render_block(&role.claude_skills));

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
        let exec: usta_providers::ToolExec = std::sync::Arc::new(move |name, input| {
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
                                                db2.insert_event(&ws2, &from, &t2, &s2, now_ms(), &[])
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

        let pm = usta_pm::Pm::new(provider, model);
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

        let pm = usta_pm::Pm::new(provider, model);
        let root = std::path::PathBuf::from(&ws.path);
        let analysis = pm
            .analyze(&root)
            .await
            .map_err(|e| Status::internal(format!("pm analyze: {e}")))?;

        // Materialize each proposed role into <ws>/.usta/roles/
        let roles_dir = root.join(".usta").join("roles");
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
        let roles_dir = std::path::PathBuf::from(&ws.path).join(".usta").join("roles");
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
        let roles_dir = std::path::PathBuf::from(&ws.path).join(".usta").join("roles");
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
            provider: usta_providers::DynProvider,
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

        let pm = usta_pm::Pm::new(provider, model);
        let proposal = pm
            .propose_from_idea(&r.idea)
            .await
            .map_err(|e| Status::internal(format!("pm propose: {e:#}")))?;

        Ok(Response::new(proposal_to_pb(proposal)))
    }

    async fn generate_grill_questions(
        &self,
        req: Request<GrillQuestionsRequest>,
    ) -> Result<Response<GrillQuestionsResponse>, Status> {
        let r = req.into_inner();
        let proposal = r.proposal.ok_or_else(|| Status::invalid_argument("missing proposal"))?;
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-haiku-4-5-20251001".into() } else { r.model };
        let provider = self.providers.get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;
        let proposal_json = serde_json::to_string(&pb_proposal_to_pm(&proposal))
            .map_err(|e| Status::internal(format!("serialize proposal: {e}")))?;
        let pm = usta_pm::Pm::new(provider, model);
        let qs = pm.generate_grill_questions(&r.idea, &proposal_json)
            .await
            .map_err(|e| Status::internal(format!("grill: {e:#}")))?;
        let items = qs.into_iter().map(|q| PbGrillQuestion {
            id: q.id,
            question: q.question,
            rationale: q.rationale,
            options: q.options,
            allow_free_text: q.allow_free_text,
        }).collect();
        Ok(Response::new(GrillQuestionsResponse { items }))
    }

    async fn refine_proposal(
        &self,
        req: Request<RefineProposalRequest>,
    ) -> Result<Response<PbProjectProposal>, Status> {
        let r = req.into_inner();
        let current = r.current_proposal.ok_or_else(|| Status::invalid_argument("missing current_proposal"))?;
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-sonnet-4-6".into() } else { r.model };
        let provider = self.providers.get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;
        let proposal_json = serde_json::to_string(&pb_proposal_to_pm(&current))
            .map_err(|e| Status::internal(format!("serialize proposal: {e}")))?;
        // Build (question, answer, rationale) triples by id-match.
        let by_id: std::collections::HashMap<String, &PbGrillQuestion> =
            r.questions.iter().map(|q| (q.id.clone(), q)).collect();
        let pairs: Vec<(String, String, String)> = r.answers.iter()
            .filter_map(|a| by_id.get(&a.id).map(|q|
                (q.question.clone(), a.answer.clone(), q.rationale.clone())))
            .collect();
        let pm = usta_pm::Pm::new(provider, model);
        let refined = pm.refine_proposal(&r.idea, &proposal_json, &pairs)
            .await
            .map_err(|e| Status::internal(format!("refine: {e:#}")))?;
        Ok(Response::new(proposal_to_pb(refined)))
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
        let roles_dir = project_dir.join(".usta").join("roles");
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
            let row = usta_core::db::WorkspaceRow {
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

        // Auto-orchestrate: publish feature.requested with the original
        // idea + first_steps and run PM to write kickoffs into role yamls.
        // This unblocks @product-manager (and other no-upstream roles) so
        // the workshop opens with a clear start point instead of a cycle.
        let kickoff_text = {
            let mut s = String::new();
            if !r.idea.trim().is_empty() {
                s.push_str(r.idea.trim());
                s.push_str("\n\n");
            } else if !proposal.summary.trim().is_empty() {
                s.push_str(proposal.summary.trim());
                s.push_str("\n\n");
            }
            if !proposal.first_steps.trim().is_empty() {
                s.push_str("First steps: ");
                s.push_str(proposal.first_steps.trim());
            }
            s.trim().to_string()
        };
        if !kickoff_text.is_empty() {
            let providers = self.providers.clone();
            let roles_lib = self.roles.clone();
            let db_arc = self.db.clone();
            let ws_id = row.id.clone();
            let ws_path = row.path.clone();
            let provider_name = if r.provider.is_empty() { "anthropic".to_string() } else { r.provider.clone() };
            let model = if r.model.is_empty() { "claude-haiku-4-5-20251001".to_string() } else { r.model.clone() };
            tokio::spawn(async move {
                let lib = roles_lib.with_workspace(std::path::Path::new(&ws_path));
                let mut team_yaml = String::new();
                for role in lib.iter() {
                    if role.scope != usta_roles::RoleScope::Workspace { continue; }
                    if let Ok(s) = serde_yaml::to_string(role) {
                        team_yaml.push_str(&format!("---\n{s}"));
                    }
                }
                // Always publish feature.requested first so UI reacts even
                // if PM call fails.
                let _ = db_arc.insert_event(&ws_id, "user", "feature.requested",
                    &kickoff_text, now_ms(), &[]);
                let Some(provider) = providers.get(&provider_name) else { return; };
                let pm = usta_pm::Pm::new(provider, model);
                let Ok((plan_summary, plan)) = pm.orchestrate_feature(
                    &team_yaml, "(scaffold)", &kickoff_text).await else { return; };
                for (role_name, task) in &plan {
                    if let Some(role) = lib.get(role_name) {
                        let mut updated = role.clone();
                        updated.kickoff = task.clone();
                        if let Ok(yaml) = serde_yaml::to_string(&updated) {
                            let _ = std::fs::write(&updated.source, yaml);
                        }
                    }
                }
                let _ = db_arc.insert_event(&ws_id, "pm", "kickoff.plan.ready",
                    &plan_summary, now_ms(), &[]);
            });
        }

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
        // Look up workspace root for file-diff
        let ws_root: Option<std::path::PathBuf> = {
            let dbq = self.db.clone();
            let wsq = ws.clone();
            let workspaces = tokio::task::spawn_blocking(move || dbq.list_workspaces())
                .await.unwrap().unwrap_or_default();
            workspaces.into_iter().find(|w| w.id == wsq).map(|w| std::path::PathBuf::from(w.path))
        };
        // Files changed since previous event (any role) using git if available.
        let files: Vec<String> = ws_root.as_ref()
            .map(|root| collect_changed_files(root))
            .unwrap_or_default();

        let (ws2, from2, topic2, summary2, files2) = (ws.clone(), from.clone(), topic.clone(), summary.clone(), files.clone());
        let db_ins = self.db.clone();
        let id = tokio::task::spawn_blocking(move || {
            db_ins.insert_event(&ws2, &from2, &topic2, &summary2, now, &files2)
        })
        .await
        .unwrap()
        .map_err(|e| Status::internal(e.to_string()))?;

        // Auto-react to subscribers.
        if !ws.is_empty() {
            let lib = match &ws_root {
                Some(root) => self.roles.with_workspace(root),
                None => (*self.roles).clone(),
            };
            dispatch_event(
                self.db.clone(), self.providers.clone(), lib.clone(),
                ws.clone(), ws_root.clone(), from.clone(), topic.clone(), summary.clone(),
            );
            // Auto-orchestrate issue: if this is a blocker topic (e.g.
            // tests.failing, security.finding), spawn PM to write fix-tasks
            // for the upstream roles that own the broken thing.
            if is_blocker_topic(&topic) {
                spawn_auto_orchestrate_issue(
                    self.db.clone(),
                    self.providers.clone(),
                    lib,
                    ws.clone(),
                    ws_root,
                    from.clone(),
                    topic.clone(),
                    summary.clone(),
                );
            }
        }

        Ok(Response::new(PbEvent {
            id,
            workspace_id: ws,
            from_role: from,
            topic,
            summary,
            created_unix_ms: now,
            files_changed: files,
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
                    files_changed: e.files_changed,
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

    async fn get_rate_limit(
        &self,
        _req: Request<Empty>,
    ) -> Result<Response<RateLimitInfo>, Status> {
        let s = usta_providers::anthropic::current_rate_limit();
        Ok(Response::new(RateLimitInfo {
            limit: s.limit,
            remaining: s.remaining,
            reset_unix_ms: s.reset_unix_ms,
            tokens_in_remaining: s.tokens_in_remaining,
            tokens_out_remaining: s.tokens_out_remaining,
            last_updated_unix_ms: s.last_updated_ms,
        }))
    }

    async fn orchestrate_issue(
        &self,
        req: Request<OrchestrateIssueRequest>,
    ) -> Result<Response<OrchestrateFeatureResponse>, Status> {
        let r = req.into_inner();
        if r.topic.trim().is_empty() {
            return Err(Status::invalid_argument("issue topic required"));
        }
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let ws = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await.unwrap()
            .map_err(|e| Status::internal(e.to_string()))?
            .into_iter().find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found("workspace not found"))?;
        let lib = self.roles.with_workspace(std::path::Path::new(&ws.path));
        let mut team_yaml = String::new();
        for r in lib.iter() {
            if r.scope != usta_roles::RoleScope::Workspace { continue; }
            if let Ok(s) = serde_yaml::to_string(r) { team_yaml.push_str(&format!("---\n{s}")); }
        }
        let db2 = self.db.clone();
        let ws_id2 = r.workspace_id.clone();
        let events = tokio::task::spawn_blocking(move || db2.list_events(&ws_id2, &[], 0, 200))
            .await.unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let event_log = events.iter()
            .map(|e| format!("@{} -> {}: {}", e.from_role, e.topic, e.summary))
            .collect::<Vec<_>>().join("\n");
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-haiku-4-5-20251001".into() } else { r.model };
        let provider = self.providers.get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;
        let pm = usta_pm::Pm::new(provider, model);
        let (summary, plan) = pm.orchestrate_issue(
            &team_yaml, &event_log, &r.from_role, &r.topic, &r.summary,
        ).await.map_err(|e| Status::internal(format!("pm orchestrate_issue: {e}")))?;
        let mut applied: Vec<PbAffectedRole> = Vec::new();
        for (role_name, task) in &plan {
            if let Some(role) = lib.get(role_name) {
                let mut updated = role.clone();
                updated.kickoff = task.clone();
                if let Ok(yaml) = serde_yaml::to_string(&updated) {
                    let _ = std::fs::write(&updated.source, yaml);
                }
                applied.push(PbAffectedRole { role_name: role_name.clone(), task: task.clone() });
            }
        }
        Ok(Response::new(OrchestrateFeatureResponse {
            plan_summary: summary,
            roles: applied,
        }))
    }

    async fn orchestrate_feature(
        &self,
        req: Request<OrchestrateFeatureRequest>,
    ) -> Result<Response<OrchestrateFeatureResponse>, Status> {
        let r = req.into_inner();
        if r.feature_text.trim().is_empty() {
            return Err(Status::invalid_argument("feature_text required"));
        }
        // Look up workspace
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let ws = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await.unwrap()
            .map_err(|e| Status::internal(e.to_string()))?
            .into_iter().find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found("workspace not found"))?;
        let lib = self.roles.with_workspace(std::path::Path::new(&ws.path));
        // Build team yaml blob
        let mut team_yaml = String::new();
        for r in lib.iter() {
            if r.scope != usta_roles::RoleScope::Workspace { continue; }
            if let Ok(s) = serde_yaml::to_string(r) {
                team_yaml.push_str(&format!("---\n{s}"));
            }
        }
        // Event log
        let db2 = self.db.clone();
        let ws_id2 = r.workspace_id.clone();
        let events = tokio::task::spawn_blocking(move || db2.list_events(&ws_id2, &[], 0, 200))
            .await.unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let event_log = events.iter()
            .map(|e| format!("@{} -> {}: {}", e.from_role, e.topic, e.summary))
            .collect::<Vec<_>>().join("\n");
        // Provider + model
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-haiku-4-5-20251001".into() } else { r.model };
        let provider = self.providers.get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;
        let pm = usta_pm::Pm::new(provider, model);
        let (summary, plan) = pm.orchestrate_feature(&team_yaml, &event_log, &r.feature_text)
            .await
            .map_err(|e| Status::internal(format!("pm orchestrate: {e}")))?;
        // Publish the request event itself
        let _ = self.db.insert_event(&r.workspace_id, "user", "feature.requested", &r.feature_text, now_ms(), &[]);
        // For each affected role: write new kickoff into yaml
        let mut applied: Vec<PbAffectedRole> = Vec::new();
        for (role_name, task) in &plan {
            if let Some(role) = lib.get(role_name) {
                let mut updated = role.clone();
                updated.kickoff = task.clone();
                if let Ok(yaml) = serde_yaml::to_string(&updated) {
                    let _ = std::fs::write(&updated.source, yaml);
                }
                applied.push(PbAffectedRole {
                    role_name: role_name.clone(),
                    task: task.clone(),
                });
            }
        }
        Ok(Response::new(OrchestrateFeatureResponse {
            plan_summary: summary,
            roles: applied,
        }))
    }

    async fn regenerate_kickoff(
        &self,
        req: Request<RegenerateKickoffRequest>,
    ) -> Result<Response<RegenerateKickoffResponse>, Status> {
        let r = req.into_inner();
        if r.workspace_id.is_empty() || r.role_name.is_empty() {
            return Err(Status::invalid_argument("workspace_id and role_name required"));
        }
        // Look up workspace
        let db = self.db.clone();
        let ws_id = r.workspace_id.clone();
        let ws = tokio::task::spawn_blocking(move || db.list_workspaces())
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?
            .into_iter()
            .find(|w| w.id == ws_id)
            .ok_or_else(|| Status::not_found("workspace not found"))?;
        // Load workspace-scoped roles
        let lib = self.roles.with_workspace(std::path::Path::new(&ws.path));
        let role = lib.get(&r.role_name)
            .ok_or_else(|| Status::not_found(format!("role '{}' not found", r.role_name)))?
            .clone();
        // Read role yaml from disk for the source-of-truth text
        let role_yaml = std::fs::read_to_string(&role.source)
            .unwrap_or_else(|_| serde_yaml::to_string(&role).unwrap_or_default());
        // Build event log
        let db2 = self.db.clone();
        let ws_id2 = r.workspace_id.clone();
        let events = tokio::task::spawn_blocking(move || db2.list_events(&ws_id2, &[], 0, 200))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let event_log = events.iter()
            .map(|e| format!("@{} -> {}: {}", e.from_role, e.topic, e.summary))
            .collect::<Vec<_>>()
            .join("\n");
        // Recent chat history for this role (last 12 assistant lines)
        let db3 = self.db.clone();
        let ws_id3 = r.workspace_id.clone();
        let role_name3 = r.role_name.clone();
        let hist = tokio::task::spawn_blocking(move || db3.list_agent_history(&ws_id3, &role_name3, 12))
            .await
            .unwrap()
            .map_err(|e| Status::internal(e.to_string()))?;
        let recent_work = hist.iter()
            .filter(|m| m.role == "assistant")
            .map(|m| m.content.chars().take(400).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n---\n");
        // Provider + model defaults
        let provider_name = if r.provider.is_empty() { "anthropic".into() } else { r.provider };
        let model = if r.model.is_empty() { "claude-haiku-4-5-20251001".into() } else { r.model };
        let provider = self.providers
            .get(&provider_name)
            .ok_or_else(|| Status::not_found(format!("unknown provider '{provider_name}'")))?;
        let pm = usta_pm::Pm::new(provider, model);
        let new_kickoff = pm.regenerate_kickoff(&role_yaml, &event_log, &recent_work)
            .await
            .map_err(|e| Status::internal(format!("pm regen: {e}")))?;
        // Persist: overwrite role yaml with updated kickoff field
        let mut updated = role.clone();
        updated.kickoff = new_kickoff.clone();
        if let Ok(yaml) = serde_yaml::to_string(&updated) {
            let _ = std::fs::write(&updated.source, yaml);
        }
        Ok(Response::new(RegenerateKickoffResponse {
            role_name: r.role_name,
            kickoff: new_kickoff,
        }))
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
                .unwrap_or_else(|_| "ustad=info,tower=warn".into()),
        )
        .init();

    let args = Args::parse();
    let socket_path = args.socket.unwrap_or_else(default_socket_path);
    let data_dir = args.data_dir.unwrap_or_else(default_data_dir);
    let db_path = data_dir.join("usta.db");

    let db = Db::open(&db_path).context("open db")?;
    info!(db = %db_path.display(), "db ready");

    if socket_path.exists() {
        // Probe: if something accepts on this socket, another daemon is alive.
        // We refuse rather than stomp.
        if probe_socket_alive(&socket_path) {
            anyhow::bail!(
                "another ustad is already listening on {} — refusing to start",
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

    info!(socket = %socket_path.display(), "ustad listening");

    let roles = RoleLibrary::load_defaults();
    info!(count = roles.len(), "roles loaded");

    let svc = UstaSvc {
        db: Arc::new(db),
        pty: Arc::new(PtyManager::new()),
        providers: Arc::new(ProviderRegistry::with_defaults()),
        embedder: Arc::new(OnceCell::new()),
        roles: Arc::new(roles),
        tools: Arc::new(ToolRegistry::with_defaults()),
        approvals: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        socket_path: socket_path.to_string_lossy().into_owned(),
    };

    // Auto-completion watcher: detects when a role's CLI agent went idle
    // after finishing work but forgot to call publish_event via MCP.
    spawn_idle_watcher(svc.db.clone(), svc.roles.clone(), svc.providers.clone());

    if let Err(e) = Server::builder()
        .add_service(UstaServer::new(svc))
        .serve_with_incoming(stream)
        .await
    {
        warn!(error = %e, "server exited");
    }

    Ok(())
}
