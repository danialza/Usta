use anyhow::{Context, Result};
use atelier_core::default_socket_path;
use atelier_proto::v1::{
    atelier_client::AtelierClient, pty_client_msg::Kind as PtyCKind,
    pty_server_msg::Kind as PtySKind, ChatMessage, ChatRequest, CloseTerminalRequest,
    CreateTerminalRequest, Empty, ListTerminalsRequest, OpenWorkspaceRequest, PingRequest,
    PtyAttach, PtyClientMsg, PtyInput, PtyResize,
};
use clap::{Parser, Subcommand};
use crossterm::terminal;
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
    Ping,
    Open { path: PathBuf },
    List,
    Providers,
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
}

#[derive(Subcommand, Debug)]
enum TermCmd {
    /// Create a new terminal in a workspace.
    New {
        workspace_id: String,
        #[arg(long, default_value = "")]
        shell: String,
    },
    /// List terminals (optionally filtered by workspace).
    List {
        #[arg(long, default_value = "")]
        workspace_id: String,
    },
    /// Close a terminal by id.
    Close { id: String },
    /// Attach interactively to a terminal. Ctrl-Q to detach.
    Attach { id: String },
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
            let r = client.ping(PingRequest { client_name: "ateliercli".into() }).await?.into_inner();
            println!("daemon  : v{}", r.daemon_version);
            println!("server  : {}ms", r.server_unix_ms);
            println!("greeting: {}", r.greeting);
        }
        Cmd::Open { path } => {
            let r = client
                .open_workspace(OpenWorkspaceRequest { path: path.to_string_lossy().into() })
                .await?
                .into_inner();
            println!("opened  : {} ({})", r.name, r.id);
            println!("path    : {}", r.path);
        }
        Cmd::List => {
            let r = client.list_workspaces(Empty {}).await?.into_inner();
            if r.items.is_empty() { println!("(no workspaces)"); }
            for w in r.items { println!("- {}  {}  {}", w.id, w.name, w.path); }
        }
        Cmd::Providers => {
            let r = client.list_providers(Empty {}).await?.into_inner();
            for p in r.items {
                let m = if p.available { "✓" } else { "✗" };
                println!("{m} {:<10}  models: {}", p.name, p.default_models.join(", "));
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
                if !t.error.is_empty() { eprintln!("\n[error] {}", t.error); std::process::exit(1); }
                if !t.text.is_empty() { out.write_all(t.text.as_bytes())?; out.flush()?; }
                if t.done { writeln!(out, "\n--- done ({}) ---", t.stop_reason)?; break; }
            }
        }
        Cmd::Term { sub } => match sub {
            TermCmd::New { workspace_id, shell } => {
                let (cols, rows) = terminal::size().unwrap_or((120, 32));
                let r = client.create_terminal(CreateTerminalRequest {
                    workspace_id,
                    shell,
                    cwd: String::new(),
                    cols: cols as i32,
                    rows: rows as i32,
                }).await?.into_inner();
                println!("created : {}", r.id);
                println!("shell   : {}", r.shell);
                println!("cwd     : {}", r.cwd);
            }
            TermCmd::List { workspace_id } => {
                let r = client.list_terminals(ListTerminalsRequest { workspace_id }).await?.into_inner();
                if r.items.is_empty() { println!("(no terminals)"); }
                for t in r.items {
                    let mark = if t.alive { "●" } else { "○" };
                    println!("{mark} {}  ws={}  {}  {}", t.id, t.workspace_id, t.shell, t.cwd);
                }
            }
            TermCmd::Close { id } => {
                client.close_terminal(CloseTerminalRequest { id: id.clone() }).await?;
                println!("closed  : {id}");
            }
            TermCmd::Attach { id } => {
                attach(&mut client, id).await?;
            }
        }
    }
    Ok(())
}

async fn attach(client: &mut AtelierClient<tonic::transport::Channel>, id: String) -> Result<()> {
    use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (cols, rows) = terminal::size().unwrap_or((120, 32));

    let (tx, rx) = mpsc::channel::<PtyClientMsg>(64);
    // First frame: Attach.
    tx.send(PtyClientMsg { kind: Some(PtyCKind::Attach(PtyAttach { terminal_id: id.clone() })) })
        .await
        .ok();
    // Send initial resize.
    tx.send(PtyClientMsg { kind: Some(PtyCKind::Resize(PtyResize { cols: cols as i32, rows: rows as i32 })) })
        .await
        .ok();

    let outbound = ReceiverStream::new(rx);
    let mut inbound = client.stream_pty(outbound).await?.into_inner();

    enable_raw_mode()?;
    eprintln!("\r\n[attached to {id}. Ctrl-Q to detach]\r\n");

    // stdin → input pump
    let tx_in = tx.clone();
    let stdin_task = tokio::spawn(async move {
        let mut stdin = tokio::io::stdin();
        let mut buf = [0u8; 1024];
        loop {
            let n = match stdin.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            // Ctrl-Q (0x11) detaches.
            if buf[..n].contains(&0x11) { break; }
            if tx_in
                .send(PtyClientMsg { kind: Some(PtyCKind::Input(PtyInput { data: buf[..n].to_vec() })) })
                .await
                .is_err()
            { break; }
        }
    });

    // server → stdout
    let mut stdout = tokio::io::stdout();
    let mut exited = false;
    while let Some(msg) = inbound.next().await {
        let msg = match msg {
            Ok(m) => m,
            Err(e) => { eprintln!("\r\n[stream error: {e}]\r\n"); break; }
        };
        match msg.kind {
            Some(PtySKind::Output(o)) => {
                stdout.write_all(&o.data).await.ok();
                stdout.flush().await.ok();
            }
            Some(PtySKind::Exit(e)) => {
                eprintln!("\r\n[exit: {}]\r\n", e.reason);
                exited = true;
                break;
            }
            Some(PtySKind::Error(e)) => {
                eprintln!("\r\n[error: {}]\r\n", e.message);
            }
            None => {}
        }
        if stdin_task.is_finished() { break; }
    }

    disable_raw_mode().ok();
    stdin_task.abort();
    if !exited {
        eprintln!("[detached]");
    }
    Ok(())
}
