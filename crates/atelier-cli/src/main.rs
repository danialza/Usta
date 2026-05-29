mod daemon_ctl;
mod state;

use anyhow::{Context, Result};
use atelier_core::default_socket_path;
use atelier_proto::v1::{
    atelier_client::AtelierClient, pty_client_msg::Kind as PtyCKind,
    pty_server_msg::Kind as PtySKind, AnalyzeRequest, ApplyTeamRequest, ChatMessage, ChatRequest,
    CloseTerminalRequest, CreateTerminalRequest, Empty, IndexRequest, ListRolesRequest,
    ListTerminalsRequest, ListToolsRequest, OpenWorkspaceRequest, PingRequest, PtyAttach,
    PtyClientMsg, PtyInput, PtyResize, RoleChatRequest, SearchRequest, TeamChatRequest,
};
use chrono::{Local, TimeZone};
use clap::{Parser, Subcommand};
use crossterm::terminal;
use owo_colors::OwoColorize;
use state::CliState;
use std::io::Write;
use std::path::PathBuf;
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt;
use tonic::transport::{Endpoint, Uri};
use tower::service_fn;

#[derive(Parser, Debug)]
#[command(name = "ateliercli", version, about = "Atelier CLI client")]
struct Args {
    #[arg(long, global = true)]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Daemon health check.
    Ping,
    /// Daemon lifecycle.
    Daemon {
        #[command(subcommand)]
        sub: DaemonCmd,
    },
    /// Run the full self-check (auto-starts daemon).
    Doctor,
    /// Open a workspace by path.
    Open { path: PathBuf },
    /// List open workspaces.
    List,
    /// Set the active workspace by path (opens it if needed).
    Use { path: PathBuf },
    /// Show the current active workspace.
    Active,
    /// List configured providers.
    Providers,
    /// Streaming chat.
    Chat {
        #[arg(short, long, default_value = "anthropic")]
        provider: String,
        #[arg(short, long)]
        model: String,
        #[arg(short, long, default_value = "")]
        system: String,
        #[arg(long, default_value_t = 1024)]
        max_tokens: i32,
        prompt: Vec<String>,
    },
    /// Terminal subcommands.
    Term {
        #[command(subcommand)]
        sub: TermCmd,
    },
    /// Index a workspace for semantic search.
    Index {
        #[arg(long, default_value = "")]
        workspace_id: String,
    },
    /// Semantic search over an indexed workspace.
    Search {
        #[arg(long, default_value = "")]
        workspace_id: String,
        #[arg(short, long, default_value_t = 5)]
        k: i32,
        query: Vec<String>,
    },
    /// Role subcommands.
    Role {
        #[command(subcommand)]
        sub: RoleCmd,
    },
    /// Team subcommands (workspace-scoped roles).
    Team {
        #[command(subcommand)]
        sub: TeamCmd,
    },
    /// Tool catalog (capabilities the daemon can offer to roles).
    Tools {
        #[command(subcommand)]
        sub: ToolsCmd,
    },
    /// PM orchestrator: identify stack + propose team.
    Analyze {
        #[arg(long, default_value = "")]
        workspace_id: String,
        #[arg(short, long, default_value = "anthropic")]
        provider: String,
        #[arg(short, long, default_value = "claude-sonnet-4-6")]
        model: String,
    },
}

#[derive(Subcommand, Debug)]
enum DaemonCmd {
    Start,
    Stop,
    Status,
}

#[derive(Subcommand, Debug)]
enum RoleCmd {
    /// List all loaded roles (including workspace-scoped if active ws set).
    List,
    /// Show metadata for a role.
    Show { name: String },
    /// Streaming chat as a role (uses active workspace's overrides if set).
    Chat {
        name: String,
        #[arg(short, long, default_value = "")]
        provider: String,
        #[arg(short, long, default_value = "")]
        model: String,
        #[arg(long, default_value_t = 1024)]
        max_tokens: i32,
        prompt: Vec<String>,
    },
}

#[derive(Subcommand, Debug)]
enum TeamCmd {
    /// Analyze workspace and persist proposed roles as workspace YAMLs.
    Apply {
        #[arg(long, default_value = "")]
        workspace_id: String,
        #[arg(short, long, default_value = "anthropic")]
        provider: String,
        #[arg(short, long, default_value = "claude-sonnet-4-6")]
        model: String,
    },
    /// List workspace roles only (filtered).
    List {
        #[arg(long, default_value = "")]
        workspace_id: String,
    },
    /// Send a message with @mentions to one or more roles in parallel.
    Chat {
        #[arg(long, default_value = "")]
        workspace_id: String,
        #[arg(short, long, default_value = "")]
        model: String,
        prompt: Vec<String>,
    },
}

#[derive(Subcommand, Debug)]
enum ToolsCmd {
    /// List all tools, or only those allowed for --role.
    List {
        #[arg(long, default_value = "")]
        role: String,
        #[arg(long, default_value = "")]
        workspace_id: String,
    },
}

#[derive(Subcommand, Debug)]
enum TermCmd {
    /// Create a terminal. Defaults to the active workspace if --workspace-id omitted.
    New {
        #[arg(long, default_value = "")]
        workspace_id: String,
        #[arg(long, default_value = "")]
        shell: String,
    },
    List {
        #[arg(long, default_value = "")]
        workspace_id: String,
    },
    Close { id: String },
    Attach { id: String },
}

fn colorize(s: &str, color: &str) -> String {
    match color {
        "cyan"    => s.cyan().to_string(),
        "magenta" => s.magenta().to_string(),
        "yellow"  => s.yellow().to_string(),
        "green"   => s.green().to_string(),
        "blue"    => s.blue().to_string(),
        "red"     => s.red().to_string(),
        _         => s.to_string(),
    }
}

fn resolve_ws(arg: String) -> Result<String> {
    if !arg.is_empty() { return Ok(arg); }
    CliState::load()
        .active_workspace_id
        .ok_or_else(|| anyhow::anyhow!("no active workspace — run `ateliercli use <path>` or pass --workspace-id"))
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { return s.to_string(); }
    let head: String = s.chars().take(max.saturating_sub(1)).collect();
    format!("{head}…")
}

fn fmt_ms(ms: i64) -> String {
    Local
        .timestamp_millis_opt(ms)
        .single()
        .map(|d| d.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| ms.to_string())
}

async fn connect(socket: PathBuf) -> Result<AtelierClient<tonic::transport::Channel>> {
    let channel = Endpoint::try_from("http://[::]:50051")?
        .connect_with_connector(service_fn(move |_: Uri| {
            let path = socket.clone();
            async move {
                let stream = UnixStream::connect(path).await?;
                Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(stream))
            }
        }))
        .await
        .context("connect to atelierd UDS")?;
    Ok(AtelierClient::new(channel))
}

fn find_daemon_bin() -> PathBuf {
    // Sibling next to ateliercli (same target dir).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join("atelierd");
            if p.exists() { return p; }
        }
    }
    PathBuf::from("atelierd")
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let sock = args.socket.clone().unwrap_or_else(default_socket_path);

    // Commands that do not need a connection.
    match &args.cmd {
        Cmd::Daemon { sub } => return run_daemon(sub, &sock),
        Cmd::Active => return show_active(),
        _ => {}
    }

    let mut client = match connect(sock.clone()).await {
        Ok(c) => c,
        Err(e) => {
            // For doctor, attempt auto-start.
            if matches!(args.cmd, Cmd::Doctor) {
                eprintln!("{} daemon not reachable, starting...", "·".dimmed());
                let bin = find_daemon_bin();
                let pid = daemon_ctl::start(&bin, &sock)?;
                eprintln!("{} started (pid {pid})", "✓".green());
                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                connect(sock.clone()).await?
            } else {
                eprintln!("{} {e}\n   hint: `ateliercli daemon start`", "✗".red());
                std::process::exit(1);
            }
        }
    };

    match args.cmd {
        Cmd::Ping => {
            let r = client.ping(PingRequest { client_name: "ateliercli".into() }).await?.into_inner();
            println!("{} v{}", "daemon  ".dimmed(), r.daemon_version.bold());
            println!("{} {}ms", "server  ".dimmed(), r.server_unix_ms);
            println!("{} {}", "greeting".dimmed(), r.greeting);
        }
        Cmd::Open { path } => {
            let abs = path.canonicalize().unwrap_or(path);
            let r = client
                .open_workspace(OpenWorkspaceRequest { path: abs.to_string_lossy().into() })
                .await?
                .into_inner();
            println!("{} {} {}", "✓".green(), r.name.bold(), format!("({})", r.id).dimmed());
            println!("  {}", r.path.dimmed());
        }
        Cmd::Use { path } => {
            let abs = path.canonicalize().context("canonicalize path")?;
            let r = client
                .open_workspace(OpenWorkspaceRequest { path: abs.to_string_lossy().into() })
                .await?
                .into_inner();
            let mut st = CliState::load();
            st.active_workspace_path = Some(r.path.clone());
            st.active_workspace_id = Some(r.id.clone());
            st.save()?;
            println!("{} active workspace: {} {}", "✓".green(), r.name.bold(), format!("({})", r.id).dimmed());
        }
        Cmd::Active => unreachable!(),
        Cmd::List => {
            let r = client.list_workspaces(Empty {}).await?.into_inner();
            if r.items.is_empty() {
                println!("{}", "(no workspaces)".dimmed());
            }
            let active = CliState::load().active_workspace_id;
            for w in r.items {
                let mark = if Some(&w.id) == active.as_ref() { "★".yellow().to_string() } else { " ".to_string() };
                println!("{mark} {}  {}  {}  {}",
                    w.id.dimmed(),
                    w.name.bold(),
                    fmt_ms(w.opened_unix_ms).dimmed(),
                    w.path,
                );
            }
        }
        Cmd::Providers => {
            let r = client.list_providers(Empty {}).await?.into_inner();
            for p in r.items {
                let mark = if p.available { "✓".green().to_string() } else { "✗".red().to_string() };
                println!("{mark} {:<10}  {}", p.name.bold(), p.default_models.join(", ").dimmed());
            }
        }
        Cmd::Chat { provider, model, system, max_tokens, prompt } => {
            let prompt = prompt.join(" ");
            if prompt.trim().is_empty() { anyhow::bail!("prompt is empty"); }
            let req = ChatRequest {
                provider, model, system, max_tokens,
                messages: vec![ChatMessage { role: "user".into(), content: prompt }],
            };
            let mut s = client.chat(req).await?.into_inner();
            let stdout = std::io::stdout();
            let mut out = stdout.lock();
            while let Some(item) = s.next().await {
                let t = item?;
                if !t.error.is_empty() { eprintln!("\n{} {}", "✗".red(), t.error); std::process::exit(1); }
                if !t.text.is_empty() { out.write_all(t.text.as_bytes())?; out.flush()?; }
                if t.done { writeln!(out, "\n{} done ({})", "·".dimmed(), t.stop_reason.dimmed())?; break; }
            }
        }
        Cmd::Term { sub } => match sub {
            TermCmd::New { workspace_id, shell } => {
                let ws_id = if workspace_id.is_empty() {
                    CliState::load()
                        .active_workspace_id
                        .ok_or_else(|| anyhow::anyhow!("no active workspace — run `ateliercli use <path>` first or pass --workspace-id"))?
                } else { workspace_id };
                let (cols, rows) = terminal::size().unwrap_or((120, 32));
                let r = client.create_terminal(CreateTerminalRequest {
                    workspace_id: ws_id,
                    shell, cwd: String::new(),
                    cols: cols as i32, rows: rows as i32,
                    command: String::new(),
                    role: String::new(),
                }).await?.into_inner();
                println!("{} {}", "✓".green(), r.id.bold());
                println!("  {} {}", "shell".dimmed(), r.shell);
                println!("  {} {}", "cwd  ".dimmed(), r.cwd);
            }
            TermCmd::List { workspace_id } => {
                let r = client.list_terminals(ListTerminalsRequest { workspace_id }).await?.into_inner();
                if r.items.is_empty() {
                    println!("{}", "(no terminals)".dimmed());
                }
                for t in r.items {
                    let mark = if t.alive { "●".green().to_string() } else { "○".dimmed().to_string() };
                    println!("{mark} {}  {}  {}  {}",
                        t.id.dimmed(),
                        t.shell.bold(),
                        fmt_ms(t.created_unix_ms).dimmed(),
                        t.cwd,
                    );
                }
            }
            TermCmd::Close { id } => {
                client.close_terminal(CloseTerminalRequest { id: id.clone() }).await?;
                println!("{} closed {}", "✓".green(), id);
            }
            TermCmd::Attach { id } => { attach(&mut client, id).await?; }
        },
        Cmd::Index { workspace_id } => {
            let ws_id = resolve_ws(workspace_id)?;
            let mut s = client.index_workspace(IndexRequest { workspace_id: ws_id }).await?.into_inner();
            use std::io::Write as _;
            let stderr = std::io::stderr();
            let mut err = stderr.lock();
            while let Some(item) = s.next().await {
                let p = item?;
                if p.done {
                    writeln!(err, "\r{} indexed {} files, {} chunks                              ",
                        "✓".green(), p.files_indexed, p.chunks)?;
                    break;
                }
                write!(err, "\r{} seen {:>5}  indexed {:>5}  chunks {:>6}  {} ",
                    "·".dimmed(),
                    p.files_seen,
                    p.files_indexed,
                    p.chunks,
                    truncate(&p.current_path, 40).dimmed(),
                )?;
                err.flush()?;
            }
        }
        Cmd::Search { workspace_id, k, query } => {
            let query = query.join(" ");
            if query.trim().is_empty() { anyhow::bail!("empty query"); }
            let ws_id = resolve_ws(workspace_id)?;
            let r = client.search_workspace(SearchRequest { workspace_id: ws_id, query: query.clone(), k }).await?.into_inner();
            if r.items.is_empty() { println!("{}", "(no hits)".dimmed()); }
            for (i, h) in r.items.iter().enumerate() {
                println!("{} {:.3}  {}:{}-{}",
                    format!("#{}", i + 1).bold(),
                    h.score,
                    h.path.bold(),
                    h.start_line,
                    h.end_line,
                );
                for line in h.snippet.lines().take(6) {
                    println!("    {}", line.dimmed());
                }
                if h.snippet.lines().count() > 6 { println!("    {}", "…".dimmed()); }
                println!();
            }
        }
        Cmd::Role { sub } => match sub {
            RoleCmd::List => {
                let ws_id = CliState::load().active_workspace_id.unwrap_or_default();
                let r = client.list_roles(ListRolesRequest { workspace_id: ws_id }).await?.into_inner();
                if r.items.is_empty() {
                    println!("{}", "(no roles found — check roles/ dir)".dimmed());
                }
                for role in r.items {
                    let scope_tag = match role.scope.as_str() {
                        "workspace" => "[ws]".yellow().to_string(),
                        "user"      => "[user]".cyan().to_string(),
                        _           => "[builtin]".dimmed().to_string(),
                    };
                    println!("{} {} {}  {}",
                        role.emoji,
                        role.name.bold(),
                        scope_tag,
                        role.description.dimmed(),
                    );
                    println!("    {} {} / {}", "model".dimmed(), role.default_provider, role.default_model);
                    if !role.allowed_tools.is_empty() {
                        println!("    {} {}", "tools".dimmed(), role.allowed_tools.join(", "));
                    }
                }
            }
            RoleCmd::Show { name } => {
                let ws_id = CliState::load().active_workspace_id.unwrap_or_default();
                let r = client.list_roles(ListRolesRequest { workspace_id: ws_id }).await?.into_inner();
                let role = r.items.iter().find(|x| x.name == name)
                    .ok_or_else(|| anyhow::anyhow!("role '{name}' not found"))?;
                println!("{} {}  [{}]", role.emoji, role.name.bold(), role.scope);
                println!("  {} {}", "desc    ".dimmed(), role.description);
                println!("  {} {}", "provider".dimmed(), role.default_provider);
                println!("  {} {}", "model   ".dimmed(), role.default_model);
                println!("  {} {}", "tools   ".dimmed(), role.allowed_tools.join(", "));
                println!("  {} {}", "source  ".dimmed(), role.source_path);
            }
            RoleCmd::Chat { name, provider, model, max_tokens, prompt } => {
                let prompt = prompt.join(" ");
                if prompt.trim().is_empty() { anyhow::bail!("empty prompt"); }
                let ws_id = CliState::load().active_workspace_id.unwrap_or_default();
                let mut s = client.role_chat(RoleChatRequest {
                    role_name: name,
                    user_msg: prompt,
                    provider, model, max_tokens,
                    workspace_id: ws_id,
                }).await?.into_inner();
                let stdout = std::io::stdout();
                let mut out = stdout.lock();
                while let Some(item) = s.next().await {
                    let t = item?;
                    if !t.error.is_empty() { eprintln!("\n{} {}", "✗".red(), t.error); std::process::exit(1); }
                    if !t.text.is_empty() { out.write_all(t.text.as_bytes())?; out.flush()?; }
                    if t.done { writeln!(out, "\n{} done ({})", "·".dimmed(), t.stop_reason.dimmed())?; break; }
                }
            }
        },
        Cmd::Team { sub } => match sub {
            TeamCmd::Apply { workspace_id, provider, model } => {
                let ws_id = resolve_ws(workspace_id)?;
                eprintln!("{} analyzing + applying team ({} / {}) ...", "·".dimmed(), provider, model);
                let r = client.apply_team(ApplyTeamRequest {
                    workspace_id: ws_id,
                    provider, model,
                }).await?.into_inner();

                if let Some(a) = &r.analysis {
                    println!();
                    println!("{} {}", "summary".bold(), a.summary);
                    println!();
                    println!("{}", "stack".bold());
                    for t in &a.stack {
                        let cat = if t.category.is_empty() { String::new() } else { format!(" [{}]", t.category) };
                        println!("  • {}{}", t.name, cat.dimmed());
                    }
                    println!();
                    println!("{}", "team (now workspace-scoped)".bold());
                    for m in &a.team {
                        println!("  {} {} {}", m.emoji, m.name.bold(), format!("({})", m.recommended_model).dimmed());
                        println!("    {} {}", "why  ".dimmed(), m.why);
                        if !m.tools.is_empty() {
                            println!("    {} {}", "tools".dimmed(), m.tools.join(", "));
                        }
                    }
                }
                println!();
                println!("{} wrote {} role file(s):", "✓".green(), r.written_paths.len());
                for p in &r.written_paths {
                    println!("  {}", p.dimmed());
                }
            }
            TeamCmd::List { workspace_id } => {
                let ws_id = resolve_ws(workspace_id)?;
                let r = client.list_roles(ListRolesRequest { workspace_id: ws_id }).await?.into_inner();
                let mut shown = 0;
                for role in r.items {
                    if role.scope != "workspace" { continue; }
                    shown += 1;
                    println!("{} {}  {}", role.emoji, role.name.bold(), role.description.dimmed());
                    println!("    {} {} / {}", "model".dimmed(), role.default_provider, role.default_model);
                    println!("    {} {}", "src  ".dimmed(), role.source_path.dimmed());
                }
                if shown == 0 {
                    println!("{}", "(no workspace roles yet — run `ateliercli team apply`)".dimmed());
                }
            }
            TeamCmd::Chat { workspace_id, model, prompt } => {
                let prompt = prompt.join(" ");
                if prompt.trim().is_empty() { anyhow::bail!("empty prompt"); }
                let ws_id = resolve_ws(workspace_id)?;
                let mut s = client.team_chat(TeamChatRequest {
                    workspace_id: ws_id,
                    user_msg: prompt,
                    mentions: vec![],   // auto-detect from message
                    model,
                }).await?.into_inner();
                use std::collections::HashMap;
                let mut buffers: HashMap<String, String> = HashMap::new();
                let palette = ["cyan", "magenta", "yellow", "green", "blue", "red"];
                let mut color_of: HashMap<String, &'static str> = HashMap::new();
                let mut next_color = 0;
                while let Some(item) = s.next().await {
                    let ev = item?;
                    let color = *color_of.entry(ev.role.clone()).or_insert_with(|| {
                        let c = palette[next_color % palette.len()];
                        next_color += 1;
                        c
                    });
                    if !ev.error.is_empty() {
                        eprintln!("{} {} {}", colorize(&format!("[{}]", ev.role), color), "error:".red(), ev.error);
                        continue;
                    }
                    if !ev.text.is_empty() {
                        buffers.entry(ev.role.clone()).or_default().push_str(&ev.text);
                    }
                    if ev.done {
                        let body = buffers.remove(&ev.role).unwrap_or_default();
                        println!("\n{}", colorize(&format!("─── @{} ({}) ───", ev.role, ev.stop_reason), color));
                        println!("{}\n", body);
                    }
                }
            }
        },
        Cmd::Tools { sub } => match sub {
            ToolsCmd::List { role, workspace_id } => {
                let ws_id = if workspace_id.is_empty() {
                    CliState::load().active_workspace_id.unwrap_or_default()
                } else { workspace_id };
                let r = client.list_tools(ListToolsRequest { role_name: role, workspace_id: ws_id }).await?.into_inner();
                if r.items.is_empty() { println!("{}", "(no tools)".dimmed()); }
                for t in r.items {
                    let approval = if t.needs_approval { "ask".yellow().to_string() } else { "auto".green().to_string() };
                    println!("  {} [{}] {}  {}",
                        t.name.bold(),
                        t.kind.dimmed(),
                        approval,
                        t.description.dimmed(),
                    );
                }
            }
        },
        Cmd::Analyze { workspace_id, provider, model } => {
            let ws_id = resolve_ws(workspace_id)?;
            eprintln!("{} analyzing with {} / {} ...", "·".dimmed(), provider, model);
            let r = client.analyze_workspace(AnalyzeRequest {
                workspace_id: ws_id,
                provider,
                model,
            }).await?.into_inner();

            println!();
            println!("{} {}", "summary".bold(), r.summary);
            println!();
            println!("{}", "stack".bold());
            if r.stack.is_empty() { println!("  {}", "(none)".dimmed()); }
            for t in &r.stack {
                let cat = if t.category.is_empty() { String::new() } else { format!(" [{}]", t.category) };
                println!("  • {}{}", t.name, cat.dimmed());
            }
            println!();
            println!("{}", "team".bold());
            for m in &r.team {
                println!("  {} {} {}", m.emoji, m.name.bold(), format!("({})", m.recommended_model).dimmed());
                println!("    {} {}", "why  ".dimmed(), m.why);
                if !m.tools.is_empty() {
                    println!("    {} {}", "tools".dimmed(), m.tools.join(", "));
                }
            }
        }
        Cmd::Doctor => { doctor(&mut client, &sock).await?; }
        Cmd::Daemon { .. } => unreachable!(),
    }
    Ok(())
}

fn run_daemon(sub: &DaemonCmd, sock: &std::path::Path) -> Result<()> {
    match sub {
        DaemonCmd::Start => {
            let bin = find_daemon_bin();
            let pid = daemon_ctl::start(&bin, sock)?;
            println!("{} started (pid {pid}, socket {})", "✓".green(), sock.display());
        }
        DaemonCmd::Stop => {
            let pid = daemon_ctl::stop()?;
            println!("{} stopped (pid {pid})", "✓".green());
        }
        DaemonCmd::Status => {
            let s = daemon_ctl::status(sock);
            if s.running {
                println!("{} running pid={} socket={}",
                    "●".green(),
                    s.pid.unwrap(),
                    sock.display(),
                );
            } else {
                println!("{} not running", "○".dimmed());
            }
        }
    }
    Ok(())
}

fn show_active() -> Result<()> {
    let st = CliState::load();
    match (&st.active_workspace_path, &st.active_workspace_id) {
        (Some(p), Some(id)) => {
            println!("{} {} {}", "★".yellow(), id.bold(), p);
        }
        _ => println!("{}", "(no active workspace — `ateliercli use <path>`)".dimmed()),
    }
    Ok(())
}

async fn doctor(client: &mut AtelierClient<tonic::transport::Channel>, sock: &std::path::Path) -> Result<()> {
    println!("{} {}", "atelier doctor".bold(), env!("CARGO_PKG_VERSION").dimmed());
    println!();

    // Ping.
    let r = client.ping(PingRequest { client_name: "doctor".into() }).await?.into_inner();
    println!("{} daemon v{} at {}", "✓".green(), r.daemon_version, sock.display());

    // Providers.
    let p = client.list_providers(Empty {}).await?.into_inner();
    println!("{} providers:", "·".dimmed());
    for it in p.items {
        let m = if it.available { "✓".green().to_string() } else { "✗".red().to_string() };
        println!("    {m} {}  {}", it.name, it.default_models.join(", ").dimmed());
    }

    // Workspaces.
    let w = client.list_workspaces(Empty {}).await?.into_inner();
    println!("{} {} workspaces", "·".dimmed(), w.items.len());

    // Terminals.
    let t = client.list_terminals(ListTerminalsRequest { workspace_id: String::new() }).await?.into_inner();
    let alive = t.items.iter().filter(|x| x.alive).count();
    println!("{} {} terminals ({} alive)", "·".dimmed(), t.items.len(), alive);

    // Active workspace.
    let st = CliState::load();
    if let (Some(p), Some(id)) = (&st.active_workspace_path, &st.active_workspace_id) {
        println!("{} active: {} {}", "★".yellow(), id, p.dimmed());
    } else {
        println!("{} no active workspace set", "·".dimmed());
    }

    println!();
    println!("{}", "all green.".green().bold());
    Ok(())
}

async fn attach(client: &mut AtelierClient<tonic::transport::Channel>, id: String) -> Result<()> {
    use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (cols, rows) = terminal::size().unwrap_or((120, 32));
    let (tx, rx) = mpsc::channel::<PtyClientMsg>(64);
    tx.send(PtyClientMsg { kind: Some(PtyCKind::Attach(PtyAttach { terminal_id: id.clone() })) }).await.ok();
    tx.send(PtyClientMsg { kind: Some(PtyCKind::Resize(PtyResize { cols: cols as i32, rows: rows as i32 })) }).await.ok();
    let outbound = ReceiverStream::new(rx);
    let mut inbound = client.stream_pty(outbound).await?.into_inner();

    enable_raw_mode()?;
    eprintln!("\r\n[attached to {id}. Ctrl-Q to detach]\r\n");

    let tx_in = tx.clone();
    let stdin_task = tokio::spawn(async move {
        let mut stdin = tokio::io::stdin();
        let mut buf = [0u8; 1024];
        loop {
            let n = match stdin.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if buf[..n].contains(&0x11) { break; }
            if tx_in.send(PtyClientMsg { kind: Some(PtyCKind::Input(PtyInput { data: buf[..n].to_vec() })) }).await.is_err() { break; }
        }
    });

    let mut stdout = tokio::io::stdout();
    let mut exited = false;
    while let Some(msg) = inbound.next().await {
        let msg = match msg {
            Ok(m) => m,
            Err(e) => { eprintln!("\r\n[stream error: {e}]\r\n"); break; }
        };
        match msg.kind {
            Some(PtySKind::Output(o)) => { stdout.write_all(&o.data).await.ok(); stdout.flush().await.ok(); }
            Some(PtySKind::Exit(e))   => { eprintln!("\r\n[exit: {}]\r\n", e.reason); exited = true; break; }
            Some(PtySKind::Error(e))  => { eprintln!("\r\n[error: {}]\r\n", e.message); }
            None => {}
        }
        if stdin_task.is_finished() { break; }
    }

    disable_raw_mode().ok();
    stdin_task.abort();
    if !exited { eprintln!("[detached]"); }
    Ok(())
}
