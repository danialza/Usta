use anyhow::Context;
use atelier_core::default_socket_path;
use atelier_proto::v1::{
    atelier_server::{Atelier, AtelierServer},
    Empty, OpenWorkspaceRequest, PingRequest, PingResponse, Workspace, WorkspaceList,
};
use clap::Parser;
use std::{path::PathBuf, sync::Arc};
use tokio::{net::UnixListener, sync::Mutex};
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{transport::Server, Request, Response, Status};
use tracing::info;

#[derive(Parser, Debug)]
#[command(name = "atelierd", version, about = "Atelier daemon")]
struct Args {
    /// Override socket path. Default: $XDG_RUNTIME_DIR/atelier.sock or $TMPDIR/atelier.sock.
    #[arg(long)]
    socket: Option<PathBuf>,
}

#[derive(Default)]
struct State {
    workspaces: Vec<atelier_core::workspace::Workspace>,
}

struct AtelierSvc {
    state: Arc<Mutex<State>>,
}

#[tonic::async_trait]
impl Atelier for AtelierSvc {
    async fn ping(&self, req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        let client = req.into_inner().client_name;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
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
        let proto_ws = Workspace {
            id: ws.id.clone(),
            path: ws.path.to_string_lossy().into_owned(),
            name: ws.name.clone(),
            opened_unix_ms: ws.opened_unix_ms,
        };
        self.state.lock().await.workspaces.push(ws);
        Ok(Response::new(proto_ws))
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

    // Clean stale socket.
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
    };

    Server::builder()
        .add_service(AtelierServer::new(svc))
        .serve_with_incoming(stream)
        .await?;

    Ok(())
}
