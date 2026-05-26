use anyhow::{Context, Result};
use atelier_core::default_socket_path;
use atelier_proto::v1::{
    atelier_client::AtelierClient, ChatMessage, ChatRequest, Empty, OpenWorkspaceRequest,
    PingRequest,
};
use clap::{Parser, Subcommand};
use std::io::Write;
use std::path::PathBuf;
use tokio::net::UnixStream;
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
    /// Health check.
    Ping,
    /// Open a workspace by absolute path.
    Open { path: PathBuf },
    /// List open workspaces.
    List,
    /// List configured providers.
    Providers,
    /// Streaming chat.
    Chat {
        /// Provider name: anthropic | ollama
        #[arg(short, long, default_value = "anthropic")]
        provider: String,
        /// Model id
        #[arg(short, long)]
        model: String,
        /// Optional system prompt
        #[arg(short, long, default_value = "")]
        system: String,
        /// Max tokens (0 = provider default)
        #[arg(long, default_value_t = 1024)]
        max_tokens: i32,
        /// Prompt (joined remaining args)
        prompt: Vec<String>,
    },
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

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let sock = args.socket.unwrap_or_else(default_socket_path);
    let mut client = connect(sock).await?;

    match args.cmd {
        Cmd::Ping => {
            let resp = client
                .ping(PingRequest { client_name: "ateliercli".into() })
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
        Cmd::Providers => {
            let resp = client.list_providers(Empty {}).await?.into_inner();
            for p in resp.items {
                let mark = if p.available { "✓" } else { "✗" };
                println!("{mark} {:<10}  models: {}", p.name, p.default_models.join(", "));
            }
        }
        Cmd::Chat { provider, model, system, max_tokens, prompt } => {
            let prompt = prompt.join(" ");
            if prompt.trim().is_empty() {
                anyhow::bail!("prompt is empty");
            }
            let req = ChatRequest {
                provider,
                model,
                system,
                max_tokens,
                messages: vec![ChatMessage { role: "user".into(), content: prompt }],
            };
            let mut stream = client.chat(req).await?.into_inner();
            let stdout = std::io::stdout();
            let mut out = stdout.lock();
            while let Some(item) = stream.next().await {
                let tok = item?;
                if !tok.error.is_empty() {
                    eprintln!("\n[error] {}", tok.error);
                    std::process::exit(1);
                }
                if !tok.text.is_empty() {
                    out.write_all(tok.text.as_bytes())?;
                    out.flush()?;
                }
                if tok.done {
                    writeln!(out, "\n--- done ({}) ---", tok.stop_reason)?;
                    break;
                }
            }
        }
    }
    Ok(())
}
