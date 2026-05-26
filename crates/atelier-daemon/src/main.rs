use anyhow::Context;
use atelier_core::{
    db::{Db, TerminalRow, WorkspaceRow},
    default_data_dir, default_socket_path,
    pty::{PtyManager, TerminalSpec},
};
use atelier_proto::v1::{
    atelier_server::{Atelier, AtelierServer},
    ChatRequest as PbChatReq, ChatToken, CloseTerminalRequest, CreateTerminalRequest, Empty,
    ListTerminalsRequest, OpenWorkspaceRequest, PingRequest, PingResponse, ProviderInfo,
    ProviderList, PtyClientMsg, PtyServerMsg, Terminal as PbTerminal, TerminalList, Workspace,
    WorkspaceList,
};
use atelier_providers::{ChatDelta, ChatMessage, ChatRequest, ProviderRegistry};
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
}

type TokenStream = Pin<Box<dyn futures::Stream<Item = Result<ChatToken, Status>> + Send>>;
type PtyStream = Pin<Box<dyn futures::Stream<Item = Result<PtyServerMsg, Status>> + Send>>;

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
                        yield Ok(ChatToken { text: t, done: false, stop_reason: String::new(), error: String::new() });
                    }
                    Ok(ChatDelta::Done { stop_reason }) => {
                        yield Ok(ChatToken { text: String::new(), done: true, stop_reason, error: String::new() });
                        return;
                    }
                    Err(e) => {
                        yield Ok(ChatToken { text: String::new(), done: true, stop_reason: String::new(), error: e.to_string() });
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
        let spec = TerminalSpec {
            id: id.clone(),
            shell: shell.clone(),
            cwd: cwd.clone(),
            cols,
            rows,
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

    let svc = AtelierSvc {
        db: Arc::new(db),
        pty: Arc::new(PtyManager::new()),
        providers: Arc::new(ProviderRegistry::with_defaults()),
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
