//! Daemon lifecycle helpers: start (detached spawn), stop (SIGTERM), status.

use crate::state::pid_path;
use anyhow::{anyhow, Context, Result};
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub struct DaemonStatus {
    pub running: bool,
    pub pid: Option<i32>,
    #[allow(dead_code)] // surfaced through CLI separately for now
    pub socket: Option<PathBuf>,
}

fn read_pid() -> Option<i32> {
    std::fs::read_to_string(pid_path())
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
}

fn is_alive(pid: i32) -> bool {
    // signal 0 = existence probe
    kill(Pid::from_raw(pid), None).is_ok()
}

pub fn status(socket: &std::path::Path) -> DaemonStatus {
    let pid = read_pid().filter(|p| is_alive(*p));
    DaemonStatus {
        running: pid.is_some(),
        pid,
        socket: if socket.exists() { Some(socket.to_path_buf()) } else { None },
    }
}

pub fn start(daemon_bin: &std::path::Path, socket: &std::path::Path) -> Result<i32> {
    if let Some(pid) = read_pid() {
        if is_alive(pid) {
            return Err(anyhow!("daemon already running (pid {pid})"));
        }
    }

    let log_path = pid_path().with_file_name("daemon.log");
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .with_context(|| format!("open {}", log_path.display()))?;
    let log_err = log.try_clone()?;

    let child = Command::new(daemon_bin)
        .arg("--socket")
        .arg(socket)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .with_context(|| format!("spawn {}", daemon_bin.display()))?;

    let pid = child.id() as i32;
    let p = pid_path();
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    std::fs::write(&p, pid.to_string())?;

    // Wait up to ~2s for the daemon to bind the socket.
    for _ in 0..40 {
        if socket.exists() && is_alive(pid) {
            return Ok(pid);
        }
        if !is_alive(pid) {
            return Err(anyhow!(
                "daemon (pid {pid}) died during startup — check {}",
                log_path.display()
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Ok(pid)
}

pub fn stop() -> Result<i32> {
    let pid = read_pid().ok_or_else(|| anyhow!("no pid file"))?;
    if !is_alive(pid) {
        let _ = std::fs::remove_file(pid_path());
        return Err(anyhow!("daemon not running (stale pid {pid})"));
    }
    kill(Pid::from_raw(pid), Signal::SIGTERM).context("SIGTERM")?;
    // best-effort wait briefly.
    for _ in 0..20 {
        std::thread::sleep(std::time::Duration::from_millis(50));
        if !is_alive(pid) { break; }
    }
    let _ = std::fs::remove_file(pid_path());
    Ok(pid)
}
