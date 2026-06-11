//! Role definitions. A Role describes a specialist agent: system prompt,
//! default model + provider, allowed tools, and a permission policy.
//!
//! Loading order (later overrides earlier by `name`):
//!   1. bundled roles in `<repo>/roles/`              (dev)
//!   2. `$XDG_DATA_HOME/usta/roles/`               (shared install)
//!   3. `$XDG_CONFIG_HOME/usta/roles/`             (user overrides)

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
pub struct HandoffTopics {
    #[serde(default)]
    pub publishes: Vec<String>,
    #[serde(default)]
    pub subscribes: Vec<String>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoleScope {
    Builtin,
    User,
    Workspace,
}

impl RoleScope {
    pub fn as_str(self) -> &'static str {
        match self {
            RoleScope::Builtin => "builtin",
            RoleScope::User => "user",
            RoleScope::Workspace => "workspace",
        }
    }
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
    /// Claude skill identifiers this role should load on first launch.
    /// Empty for builtins; populated by the PM when generating a team.
    #[serde(default)]
    pub claude_skills: Vec<String>,
    /// Topics this role publishes to / subscribes from on the shared
    /// workspace event bus (e.g. ["schema.changed", "api.added"]).
    #[serde(default)]
    pub handoff_topics: HandoffTopics,
    /// Optional CLI to spawn for this role (e.g. "claude", "gemini",
    /// "aider --model gemini/x"). When non-empty, the assistant pane
    /// defaults to CLI mode for this role.
    #[serde(default)]
    pub cli_command: String,
    /// One-shot kickoff message that should be sent to this role on the
    /// first pane launch (typed into the CLI / prefilled in the chat).
    #[serde(default)]
    pub kickoff: String,
    /// How this role behaves on auto-dispatched (headless) turns triggered by
    /// the event bus. "manual" (default) = read-only, describe writes;
    /// "auto" = allowed to write/exec without a human (use with care).
    #[serde(default = "default_autonomy")]
    pub autonomy: String,
    /// Source path the role was loaded from (filled in by the loader).
    #[serde(default, skip_serializing)]
    pub source: PathBuf,
    /// Where this role came from (filled in by the loader).
    #[serde(default = "default_scope", skip)]
    pub scope: RoleScope,
}

fn default_scope() -> RoleScope { RoleScope::Builtin }

fn default_provider() -> String { "anthropic".into() }

fn default_autonomy() -> String { "manual".into() }

#[derive(Debug, Default, Clone)]
pub struct RoleLibrary {
    roles: BTreeMap<String, Role>,
}

impl RoleLibrary {
    pub fn empty() -> Self { Self::default() }

    pub fn load_defaults() -> Self {
        let mut lib = Self::default();
        for dir in bundled_dirs() {
            let _ = lib.load_dir(&dir, RoleScope::Builtin);
        }
        if let Some(d) = directories::ProjectDirs::from("dev", "usta", "usta") {
            let _ = lib.load_dir(&d.data_dir().join("roles"), RoleScope::User);
            let _ = lib.load_dir(&d.config_dir().join("roles"), RoleScope::User);
        }
        lib
    }

    /// Returns a fresh library equal to `self` plus any roles found under
    /// `<workspace_root>/.usta/roles/`. Workspace roles override others
    /// with the same name.
    pub fn with_workspace(&self, workspace_root: &Path) -> Self {
        let mut out = Self { roles: self.roles.clone() };
        let ws_dir = workspace_root.join(".usta").join("roles");
        let _ = out.load_dir(&ws_dir, RoleScope::Workspace);
        out
    }

    pub fn load_dir(&mut self, dir: &Path, scope: RoleScope) -> anyhow::Result<usize> {
        if !dir.is_dir() { return Ok(0); }
        let mut n = 0usize;
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let p = entry.path();
            let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
            if !matches!(ext, "yaml" | "yml") { continue; }
            match load_file(&p, scope) {
                Ok(r) => {
                    tracing::debug!(name = %r.name, src = %p.display(), scope = scope.as_str(), "loaded role");
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

    /// Persist a role as YAML under `<dir>/<name>.yaml` and insert it into
    /// this library. Returns the absolute file path written.
    pub fn write_role(&mut self, dir: &Path, role: &Role) -> anyhow::Result<PathBuf> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(format!("{}.yaml", sanitize_name(&role.name)));
        let yaml = serde_yaml::to_string(role)?;
        std::fs::write(&path, yaml)?;
        let mut stored = role.clone();
        stored.source = path.clone();
        // Caller sets scope via reload; default-keep here.
        self.roles.insert(stored.name.clone(), stored);
        Ok(path)
    }

    pub fn get(&self, name: &str) -> Option<&Role> { self.roles.get(name) }

    pub fn iter(&self) -> impl Iterator<Item = &Role> { self.roles.values() }

    pub fn len(&self) -> usize { self.roles.len() }
    pub fn is_empty(&self) -> bool { self.roles.is_empty() }
}

fn load_file(path: &Path, scope: RoleScope) -> anyhow::Result<Role> {
    let s = std::fs::read_to_string(path)?;
    let mut role: Role = serde_yaml::from_str(&s)?;
    role.source = path.to_path_buf();
    role.scope = scope;
    Ok(role)
}

fn sanitize_name(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c.to_ascii_lowercase() } else { '-' })
        .collect()
}

fn bundled_dirs() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        // .app bundle: <exe>/../../Resources/roles  (MacOS/ -> Contents/Resources/)
        if let Some(exe_dir) = exe.parent() {
            let app_resources = exe_dir
                .parent()
                .map(|p| p.join("Resources").join("roles"));
            if let Some(r) = app_resources {
                if r.is_dir() {
                    out.push(r);
                }
            }
        }
        // dev / generic: walk up to find sibling `roles/`
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..4 {
            let Some(d) = dir.clone() else { break };
            let candidate = d.join("roles");
            if candidate.is_dir() && !out.contains(&candidate) {
                out.push(candidate);
                break;
            }
            dir = d.parent().map(Path::to_path_buf);
        }
    }
    // CWD/roles handy during `cargo run`.
    if let Ok(cwd) = std::env::current_dir() {
        let p = cwd.join("roles");
        if p.is_dir() && !out.contains(&p) {
            out.push(p);
        }
    }
    out
}
