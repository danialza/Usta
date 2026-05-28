use std::path::PathBuf;

pub mod db;
pub mod pty;
pub mod skills;
pub mod tools;
pub mod workspace;

pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Default Unix domain socket path used by atelierd.
///
/// `$XDG_RUNTIME_DIR/atelier.sock` when available, else `$TMPDIR/atelier.sock`.
pub fn default_socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(dir).join("atelier.sock");
    }
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(tmp).join("atelier.sock")
}

/// Default data dir: `~/Library/Application Support/atelier` on macOS.
pub fn default_data_dir() -> PathBuf {
    if let Some(dirs) = directories::ProjectDirs::from("dev", "atelier", "atelier") {
        return dirs.data_dir().to_path_buf();
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".atelier")
}
