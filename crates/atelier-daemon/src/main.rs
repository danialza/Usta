use anyhow::Context;
use atelier_core::default_socket_path;
use atelier_proto::v1::{
    atelier_server::{Atelier, AtelierServer},
    ChatRequest as PbChatReq, ChatToken, Empty, OpenWorkspaceRequest, PingRequest, PingResponse,
    ProviderInfo, ProviderList, Workspace, WorkspaceList,
};
use atelier_providers::{ChatDelta, ChatMessage, ChatRequest, ProviderRegistry};
use clap::Parser;
use futures::StreamExt;
use std::{path::PathBuf, pin::Pin, sync::Arc};
use tokio::{net::UnixListener, sync::Mutex};
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{transport::Server, Request, Response, Status};
use tracing::{error, info};

#[derive(Parser, Debug)]
#[command(name = "atelierd", version, about = "Atelier daemon")]
struct Args {
    #[arg(long)]
    socket: Option<PathBuf>,
}

#[derive(Default)]
struct State {
    workspaces: Vec<atelier_core::workspace::Workspace>,
}

struct AtelierSvc {
    state: Arc<Mutex<State>>,
    providers: Arc<ProviderRegistry>,
}

type TokenStream = Pin<Box<dyn futures::Stream<Item = Result<ChatToken, Status>> + Send>>;

#[tonic::async_trait]
impl Atelier for AtelierSvc {
    async fn ping(&self, req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        let client = req.into_inner().client_name;
        let now = now_ms();
        Ok(Response::new(PingResponse {
            daemon_version: atelier_core::DAEMON_VERSION.into(),
            server_unix_ms: now,
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
        let ws = atelier_core::workspace::Workspace::new(path);
        let pb = Workspace {
            id: ws.id.clone(),
            path: ws.path.to_string_lossy().into_owned(),
            name: ws.name.clone(),
            opened_unix_ms: ws.opened_unix_ms,
        };
        self.state.lock().await.workspaces.push(ws);
        Ok(Response::new(pb))
    }

    async fn list_workspaces(
        &self,
        _req: Request<Empty>,
    ) -> Result<Response<WorkspaceList>, Status> {
        let items = self
            .state
            .lock()
            .await
            .workspaces
            .iter()
            .map(|w| Workspace {
                id: w.id.clone(),
                path: w.path.to_string_lossy().into_owned(),
                name: w.name.clone(),
                opened_unix_ms: w.opened_unix_ms,
            })
            .collect();
        Ok(Response::new(WorkspaceList { items }))
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

    async fn chat(
        &self,
        req: Request<PbChatReq>,
    ) -> Result<Response<Self::ChatStream>, Status> {
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
                error!(error = %e, "provider chat failed to start");
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
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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
        state: Arc::new(Mutex::new(State::default())),
        providers: Arc::new(ProviderRegistry::with_defaults()),
    };

    Server::builder()
        .add_service(AtelierServer::new(svc))
        .serve_with_incoming(stream)
        .await?;

    Ok(())
}
