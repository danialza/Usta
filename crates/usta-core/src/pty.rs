//! Pty manager. Each terminal owns a portable_pty Master, a blocking reader
//! thread, and a blocking writer thread, bridged to async via tokio mpsc.

use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, Mutex};

#[derive(Debug, Clone)]
pub struct TerminalSpec {
    pub id: String,
    pub shell: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    /// When set, the pty runs `$shell -lc "<command>"` instead of an
    /// interactive shell (used to launch a CLI agent like `claude`/`aider`).
    pub command: Option<String>,
    /// Extra environment variables (e.g. USTA_* for the MCP bridge).
    pub extra_env: Vec<(String, String)>,
}

/// Output channel: every reader gets each chunk. broadcast so multiple
/// attachers can mirror the same pty (e.g. CLI + future UI).
pub type OutputRx = broadcast::Receiver<Vec<u8>>;

/// Cap of bytes kept in per-terminal scrollback for reattach replay.
const SCROLLBACK_CAP: usize = 256 * 1024;

pub struct Terminal {
    pub spec: TerminalSpec,
    /// Send bytes to write into pty master.
    input_tx: mpsc::Sender<Vec<u8>>,
    /// Subscribers receive output chunks from pty.
    output_tx: broadcast::Sender<Vec<u8>>,
    /// Resize handle.
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    /// Set true when child exits or terminal closed.
    closed: Arc<std::sync::atomic::AtomicBool>,
    /// Last ~256KB of output, replayed on each new attach so reattach
    /// after UI navigation shows history (pending prompts, output etc).
    scrollback: Arc<std::sync::Mutex<Vec<u8>>>,
}

impl Terminal {
    pub fn id(&self) -> &str { &self.spec.id }

    pub async fn write(&self, data: &[u8]) -> anyhow::Result<()> {
        self.input_tx
            .send(data.to_vec())
            .await
            .map_err(|_| anyhow::anyhow!("pty input channel closed"))
    }

    pub fn subscribe(&self) -> OutputRx { self.output_tx.subscribe() }

    /// Snapshot of current scrollback. Caller should send this to a freshly
    /// attached client BEFORE relaying further `subscribe()` chunks.
    pub fn scrollback(&self) -> Vec<u8> {
        self.scrollback.lock().unwrap().clone()
    }

    /// Seed the scrollback with prior session bytes (replay across restarts).
    /// Call before any client attaches. Trims to SCROLLBACK_CAP.
    pub fn prepend_scrollback(&self, data: &[u8]) {
        let mut g = self.scrollback.lock().unwrap();
        let mut new = Vec::with_capacity(data.len() + g.len());
        new.extend_from_slice(data);
        new.extend_from_slice(&g);
        if new.len() > SCROLLBACK_CAP {
            let drop_n = new.len() - SCROLLBACK_CAP;
            new.drain(..drop_n);
        }
        *g = new;
    }

    pub async fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        let m = self.master.lock().await;
        m.resize(PtySize { cols, rows, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| anyhow::anyhow!(e))?;
        Ok(())
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::Relaxed)
    }
}

pub struct PtyManager {
    terms: Mutex<HashMap<String, Arc<Terminal>>>,
}

impl PtyManager {
    pub fn new() -> Self { Self { terms: Mutex::new(HashMap::new()) } }

    pub async fn create(&self, spec: TerminalSpec) -> anyhow::Result<Arc<Terminal>> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                cols: spec.cols.max(1),
                rows: spec.rows.max(1),
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| anyhow::anyhow!(e))?;

        let mut cmd = CommandBuilder::new(&spec.shell);
        cmd.cwd(&spec.cwd);
        // Optional: launch a CLI agent via the login shell so PATH/aliases load.
        if let Some(command) = spec.command.as_ref().filter(|c| !c.trim().is_empty()) {
            cmd.arg("-lc");
            cmd.arg(command);
        }
        // pass through a minimal env
        cmd.env("TERM", std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".into()));
        cmd.env("LANG", std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".into()));
        cmd.env("HOME", std::env::var("HOME").unwrap_or_default());
        cmd.env("PATH", std::env::var("PATH").unwrap_or_default());
        for (k, v) in &spec.extra_env {
            cmd.env(k, v);
        }

        let mut child = pair.slave.spawn_command(cmd).map_err(|e| anyhow::anyhow!(e))?;
        // slave is owned by child via fd; we drop ours
        drop(pair.slave);

        let master = pair.master;
        let mut reader = master.try_clone_reader().map_err(|e| anyhow::anyhow!(e))?;
        let mut writer = master.take_writer().map_err(|e| anyhow::anyhow!(e))?;

        let (output_tx, _) = broadcast::channel::<Vec<u8>>(256);
        let (input_tx, mut input_rx) = mpsc::channel::<Vec<u8>>(64);

        let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let scrollback = Arc::new(std::sync::Mutex::new(Vec::<u8>::with_capacity(SCROLLBACK_CAP)));

        // Reader thread (blocking).
        let out_tx = output_tx.clone();
        let closed_r = closed.clone();
        let sb = scrollback.clone();
        std::thread::Builder::new()
            .name(format!("pty-read-{}", spec.id))
            .spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            let chunk = buf[..n].to_vec();
                            // Append to scrollback ring; trim head when over cap.
                            {
                                let mut g = sb.lock().unwrap();
                                g.extend_from_slice(&chunk);
                                let len = g.len();
                                if len > SCROLLBACK_CAP {
                                    let drop_n = len - SCROLLBACK_CAP;
                                    g.drain(..drop_n);
                                }
                            }
                            let _ = out_tx.send(chunk);
                        }
                        Err(_) => break,
                    }
                }
                closed_r.store(true, std::sync::atomic::Ordering::Relaxed);
            })?;

        // Writer thread (blocking, pulls from async channel via blocking_recv).
        let closed_w = closed.clone();
        std::thread::Builder::new()
            .name(format!("pty-write-{}", spec.id))
            .spawn(move || {
                while let Some(data) = input_rx.blocking_recv() {
                    if writer.write_all(&data).is_err() { break; }
                    let _ = writer.flush();
                }
                closed_w.store(true, std::sync::atomic::Ordering::Relaxed);
            })?;

        // Wait-thread: reap child to mark closed.
        let closed_c = closed.clone();
        std::thread::Builder::new()
            .name(format!("pty-wait-{}", spec.id))
            .spawn(move || {
                let _ = child.wait();
                closed_c.store(true, std::sync::atomic::Ordering::Relaxed);
            })?;

        let term = Arc::new(Terminal {
            spec: spec.clone(),
            input_tx,
            output_tx,
            master: Arc::new(Mutex::new(master)),
            closed,
            scrollback,
        });
        self.terms.lock().await.insert(spec.id.clone(), term.clone());
        Ok(term)
    }

    pub async fn get(&self, id: &str) -> Option<Arc<Terminal>> {
        self.terms.lock().await.get(id).cloned()
    }

    pub async fn list(&self) -> Vec<Arc<Terminal>> {
        self.terms.lock().await.values().cloned().collect()
    }

    pub async fn close(&self, id: &str) -> bool {
        let mut map = self.terms.lock().await;
        map.remove(id).is_some()
    }
}

impl Default for PtyManager {
    fn default() -> Self { Self::new() }
}
