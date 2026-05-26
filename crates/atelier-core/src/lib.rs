use std::path::PathBuf;

pub mod workspace;

pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Returns the default Unix domain socket path used by atelierd.
///
/// `$XDG_RUNTIME_DIR/atelier.sock` when available, else `$TMPDIR/atelier.sock`.
pub fn default_socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(dir).join("atelier.sock");
    }
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(tmp).join("atelier.sock")
}
