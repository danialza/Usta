//! Role definitions. A Role describes a specialist agent: system prompt,
//! default model + provider, allowed tools, and a permission policy.
//!
//! Loading order (later overrides earlier by `name`):
//!   1. bundled roles in `<repo>/roles/`              (dev)
//!   2. `$XDG_DATA_HOME/atelier/roles/`               (shared install)
//!   3. `$XDG_CONFIG_HOME/atelier/roles/`             (user overrides)

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    Deny,
    Ask,
    AllowSafe,
    Allow,
}

impl Default for Permission {
    fn default() -> Self { Permission::Ask }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PermissionPolicy {
    #[serde(default)]
    pub fs_read: Option<Permission>,
    #[serde(default)]
    pub fs_write: Option<Permission>,
    #[serde(default)]
    pub exec: Option<Permission>,
    #[serde(default)]
    pub network: Option<Permission>,
    #[serde(default)]
    pub secrets: Option<Permission>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Role {
    pub name: String,
    #[serde(default)]
    pub emoji: String,
    #[serde(default)]
    pub description: String,
    pub system_prompt: String,
    #[serde(default = "default_provider")]
    pub default_provider: String,
    pub default_model: String,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub permissions: PermissionPolicy,
    /// Source path the role was loaded from (filled in by the loader).
    #[serde(default, skip_serializing)]
    pub source: PathBuf,
}

fn default_provider() -> String { "anthropic".into() }

#[derive(Debug, Default)]
pub struct RoleLibrary {
    roles: BTreeMap<String, Role>,
}

impl RoleLibrary {
    pub fn empty() -> Self { Self::default() }

    pub fn load_defaults() -> Self {
        let mut lib = Self::default();
        // 1. bundled roles next to current_exe / target dir / workspace root
        for dir in bundled_dirs() {
            let _ = lib.load_dir(&dir);
        }
        // 2. shared data dir
        if let Some(d) = directories::ProjectDirs::from("dev", "atelier", "atelier") {
            let _ = lib.load_dir(&d.data_dir().join("roles"));
        }
        // 3. user config dir
        if let Some(d) = directories::ProjectDirs::from("dev", "atelier", "atelier") {
            let _ = lib.load_dir(&d.config_dir().join("roles"));
        }
        lib
    }

    pub fn load_dir(&mut self, dir: &Path) -> anyhow::Result<usize> {
        if !dir.is_dir() { return Ok(0); }
        let mut n = 0usize;
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let p = entry.path();
            let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
            if !matches!(ext, "yaml" | "yml") { continue; }
            match load_file(&p) {
                Ok(r) => {
                    tracing::debug!(name = %r.name, src = %p.display(), "loaded role");
                    self.roles.insert(r.name.clone(), r);
                    n += 1;
                }
                Err(e) => {
                    tracing::warn!(error = %e, path = %p.display(), "skip role");
                }
            }
        }
        Ok(n)
    }

    pub fn get(&self, name: &str) -> Option<&Role> { self.roles.get(name) }

    pub fn iter(&self) -> impl Iterator<Item = &Role> { self.roles.values() }

    pub fn len(&self) -> usize { self.roles.len() }
    pub fn is_empty(&self) -> bool { self.roles.is_empty() }
}

fn load_file(path: &Path) -> anyhow::Result<Role> {
    let s = std::fs::read_to_string(path)?;
    let mut role: Role = serde_yaml::from_str(&s)?;
    role.source = path.to_path_buf();
    Ok(role)
}

fn bundled_dirs() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        // target/debug/foo -> walk up to find sibling `roles/`
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..4 {
            let Some(d) = dir.clone() else { break };
            let candidate = d.join("roles");
            if candidate.is_dir() {
                out.push(candidate);
                break;
            }
            dir = d.parent().map(Path::to_path_buf);
        }
    }
    // CWD/roles is handy during `cargo run`.
    if let Ok(cwd) = std::env::current_dir() {
        let p = cwd.join("roles");
        if p.is_dir() && !out.contains(&p) {
            out.push(p);
        }
    }
    out
}
