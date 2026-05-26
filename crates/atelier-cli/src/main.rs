use anyhow::{Context, Result};
use atelier_core::default_socket_path;
use atelier_proto::v1::{atelier_client::AtelierClient, Empty, OpenWorkspaceRequest, PingRequest};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use tokio::net::UnixStream;
use tonic::transport::{Endpoint, Uri};
use tower::service_fn;

#[derive(Parser, Debug)]
#[command(name = "ateliercli", version, about = "Atelier CLI client")]
struct Args {
    /// Override socket path.
    #[arg(long, global = true)]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Health check the daemon.
    Ping,
    /// Open a workspace by absolute path.
    Open { path: PathBuf },
    /// List currently open workspaces.
    List,
}

async fn connect(socket: PathBuf) -> Result<AtelierClient<tonic::transport::Channel>> {
    // tonic over UDS — uri is a placeholder, real connect goes through the connector.
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

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let sock = args.socket.unwrap_or_else(default_socket_path);
    let mut client = connect(sock).await?;

    match args.cmd {
        Cmd::Ping => {
            let resp = client
                .ping(PingRequest {
                    client_name: "ateliercli".into(),
                })
                .await?
                .into_inner();
            println!("daemon  : v{}", resp.daemon_version);
            println!("server  : {}ms", resp.server_unix_ms);
            println!("greeting: {}", resp.greeting);
        }
        Cmd::Open { path } => {
            let resp = client
                .open_workspace(OpenWorkspaceRequest {
                    path: path.to_string_lossy().into_owned(),
                })
                .await?
                .into_inner();
            println!("opened  : {} ({})", resp.name, resp.id);
            println!("path    : {}", resp.path);
        }
        Cmd::List => {
            let resp = client.list_workspaces(Empty {}).await?.into_inner();
            if resp.items.is_empty() {
                println!("(no workspaces open)");
            }
            for w in resp.items {
                println!("- {}  {}  {}", w.id, w.name, w.path);
            }
        }
    }
    Ok(())
}
