//! CLI-local state (active workspace, daemon PID). Stored under
//! `$XDG_CONFIG_HOME/atelier/cli.toml` or platform equivalent.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct CliState {
    /// Last workspace path the user `use`d.
    pub active_workspace_path: Option<String>,
    /// Last workspace id returned by the daemon for that path.
    pub active_workspace_id: Option<String>,
}

fn config_dir() -> PathBuf {
    if let Some(d) = directories::ProjectDirs::from("dev", "atelier", "atelier") {
        return d.config_dir().to_path_buf();
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".atelier")
}

pub fn state_path() -> PathBuf { config_dir().join("cli.toml") }
pub fn pid_path() -> PathBuf { config_dir().join("daemon.pid") }

impl CliState {
    pub fn load() -> Self {
        let p = state_path();
        match std::fs::read_to_string(&p) {
            Ok(s) => toml::from_str(&s).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> std::io::Result<()> {
        let p = state_path();
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let s = toml::to_string_pretty(self).expect("serialize state");
        std::fs::write(p, s)
    }
}
