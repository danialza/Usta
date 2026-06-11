//! Usta MCP stdio server.
//!
//! Exposes the workspace event bus to MCP-capable CLI agents (Claude Code,
//! etc.) so CLI panes share the same orchestration as native panes. Speaks
//! newline-delimited JSON-RPC 2.0 on stdio and proxies to the daemon over the
//! gRPC Unix socket.
//!
//! Context from env (set by Usta when it launches a CLI pane):
//!   USTA_SOCKET        UDS path of ustad
//!   USTA_WORKSPACE_ID  workspace this agent belongs to
//!   USTA_ROLE          this agent's role name (used as event from_role)
//!
//! Tools:
//!   publish_event(topic, summary)              announce a handoff
//!   list_events(topics?, limit?)               read recent team activity
//!   wait_for_event(topics, timeout_seconds?)   block until a matching event

use usta_proto::v1::{
    usta_client::UstaClient, ListEventsRequest, PublishEventRequest,
};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream;
use tonic::transport::{Channel, Endpoint, Uri};
use tower::service_fn;

const PROTOCOL_VERSION: &str = "2024-11-05";

fn socket_path() -> PathBuf {
    if let Ok(s) = std::env::var("USTA_SOCKET") {
        if !s.is_empty() { return PathBuf::from(s); }
    }
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(tmp).join("usta.sock")
}

async fn connect() -> anyhow::Result<UstaClient<Channel>> {
    let socket = socket_path();
    let channel = Endpoint::try_from("http://[::]:50051")?
        .connect_with_connector(service_fn(move |_: Uri| {
            let p = socket.clone();
            async move {
                let s = UnixStream::connect(p).await?;
                Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(s))
            }
        }))
        .await?;
    Ok(UstaClient::new(channel))
}

fn tool_defs() -> Value {
    json!([
        {
            "name": "publish_event",
            "description": "Announce a handoff to the team. Other agents subscribed to the topic will see it (and may auto-react).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "topic": { "type": "string", "description": "dotted topic e.g. api.added, tests.needed" },
                    "summary": { "type": "string", "description": "one-line summary of what you did" }
                },
                "required": ["topic", "summary"]
            }
        },
        {
            "name": "list_events",
            "description": "List recent team activity (handoff events) for this workspace.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "topics": { "type": "array", "items": { "type": "string" }, "description": "filter to these topics (optional)" },
                    "limit": { "type": "integer", "description": "max events (default 20)" }
                }
            }
        },
        {
            "name": "wait_for_event",
            "description": "Block until a team event matching one of the given topics arrives, or timeout. Use this to wait for upstream work (e.g. QA waits for tests.needed).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "topics": { "type": "array", "items": { "type": "string" } },
                    "timeout_seconds": { "type": "integer", "description": "default 120" }
                },
                "required": ["topics"]
            }
        }
    ])
}

async fn call_tool(name: &str, args: &Value) -> anyhow::Result<String> {
    let ws = std::env::var("USTA_WORKSPACE_ID").unwrap_or_default();
    let role = std::env::var("USTA_ROLE").unwrap_or_else(|_| "cli".into());
    if ws.is_empty() {
        return Ok("error: USTA_WORKSPACE_ID not set (no workspace context)".into());
    }
    let mut client = connect().await?;

    match name {
        "publish_event" => {
            let topic = args["topic"].as_str().unwrap_or_default().to_string();
            let summary = args["summary"].as_str().unwrap_or_default().to_string();
            if topic.is_empty() { return Ok("error: topic required".into()); }
            client.publish_event(PublishEventRequest {
                workspace_id: ws, from_role: role, topic: topic.clone(), summary,
            }).await?;
            Ok(format!("published event '{topic}'"))
        }
        "list_events" => {
            let topics = args["topics"].as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                .unwrap_or_default();
            let limit = args["limit"].as_i64().unwrap_or(20) as i32;
            let r = client.list_events(ListEventsRequest {
                workspace_id: ws, topics, after_id: 0, limit,
            }).await?.into_inner();
            if r.items.is_empty() { return Ok("(no events)".into()); }
            let mut out = String::new();
            for e in r.items {
                out.push_str(&format!("#{} @{} [{}]: {}\n", e.id, e.from_role, e.topic, e.summary));
            }
            Ok(out)
        }
        "wait_for_event" => {
            let topics: Vec<String> = args["topics"].as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                .unwrap_or_default();
            if topics.is_empty() { return Ok("error: topics required".into()); }
            let timeout = args["timeout_seconds"].as_i64().unwrap_or(120).max(1);
            // Baseline: highest current id, so we only return NEW events.
            let base = client.list_events(ListEventsRequest {
                workspace_id: ws.clone(), topics: topics.clone(), after_id: 0, limit: 1,
            }).await?.into_inner();
            let mut after = base.items.last().map(|e| e.id).unwrap_or(0);
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout as u64);
            loop {
                if std::time::Instant::now() >= deadline {
                    return Ok("timeout: no matching event".into());
                }
                let r = client.list_events(ListEventsRequest {
                    workspace_id: ws.clone(), topics: topics.clone(), after_id: after, limit: 10,
                }).await?.into_inner();
                if let Some(e) = r.items.first() {
                    return Ok(format!("event #{} @{} [{}]: {}", e.id, e.from_role, e.topic, e.summary));
                }
                let _ = &mut after;
                tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
            }
        }
        other => Ok(format!("error: unknown tool '{other}'")),
    }
}

fn send(resp: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{}", serde_json::to_string(resp).unwrap_or_default());
    let _ = out.flush();
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let stdin = tokio::io::stdin();
    let mut lines = BufReader::new(stdin).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() { continue; }
        let msg: Value = match serde_json::from_str(line) { Ok(v) => v, Err(_) => continue };
        let id = msg.get("id").cloned();
        let method = msg["method"].as_str().unwrap_or("");

        // Notifications (no id) — no response.
        if id.is_none() { continue; }
        let id = id.unwrap();

        match method {
            "initialize" => {
                send(&json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": {
                        "protocolVersion": PROTOCOL_VERSION,
                        "capabilities": { "tools": {} },
                        "serverInfo": { "name": "usta", "version": env!("CARGO_PKG_VERSION") }
                    }
                }));
            }
            "tools/list" => {
                send(&json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": tool_defs() } }));
            }
            "tools/call" => {
                let params = &msg["params"];
                let name = params["name"].as_str().unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                let text = match call_tool(name, &args).await {
                    Ok(t) => t,
                    Err(e) => format!("error: {e}"),
                };
                send(&json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": { "content": [{ "type": "text", "text": text }] }
                }));
            }
            "ping" => {
                send(&json!({ "jsonrpc": "2.0", "id": id, "result": {} }));
            }
            _ => {
                send(&json!({
                    "jsonrpc": "2.0", "id": id,
                    "error": { "code": -32601, "message": format!("method not found: {method}") }
                }));
            }
        }
    }
    Ok(())
}
