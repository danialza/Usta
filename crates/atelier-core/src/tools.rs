//! Tool registry skeleton. v0 ships a static catalog matching the tool
//! names role YAMLs reference (`shell`, `fs_read`, `fs_write`, package
//! managers, scanners, deploy tools). Execution wiring lands later — this
//! lets the daemon list capabilities and intersect them with a role's
//! `allowed_tools` for upcoming permission gating.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolKind {
    Shell,
    Fs,
    Binary,
}

impl ToolKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ToolKind::Shell => "shell",
            ToolKind::Fs => "fs",
            ToolKind::Binary => "binary",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDef {
    pub name: String,
    pub kind: ToolKind,
    pub description: String,
    /// True if invoking this tool should prompt the user by default.
    #[serde(default)]
    pub needs_approval: bool,
}

pub struct ToolRegistry {
    tools: Vec<ToolDef>,
}

impl ToolRegistry {
    pub fn with_defaults() -> Self {
        use ToolKind::*;
        let mk = |name: &str, kind: ToolKind, desc: &str, approval: bool| ToolDef {
            name: name.into(),
            kind,
            description: desc.into(),
            needs_approval: approval,
        };
        Self {
            tools: vec![
                mk("shell",      Shell,  "Run a command in the project shell (pty).", true),
                mk("fs_read",    Fs,     "Read files inside the workspace.", false),
                mk("fs_write",   Fs,     "Create or modify files inside the workspace.", true),
                mk("npm",        Binary, "Run npm scripts and installs.", true),
                mk("pnpm",       Binary, "Run pnpm scripts and installs.", true),
                mk("pip",        Binary, "Install or run python packages.", true),
                mk("cargo",      Binary, "Build, test, run Rust crates.", true),
                mk("go",         Binary, "Build, test, run Go programs.", true),
                mk("docker",     Binary, "Build images and run containers.", true),
                mk("gh",         Binary, "GitHub CLI: issues, PRs, releases.", true),
                mk("flyctl",     Binary, "Deploy to Fly.io.", true),
                mk("kubectl",    Binary, "Kubernetes cluster control.", true),
                mk("terraform",  Binary, "Infrastructure as code.", true),
                mk("psql",       Binary, "PostgreSQL client.", true),
                mk("sqlite",     Binary, "SQLite client.", false),
                mk("prisma",     Binary, "Prisma ORM CLI (migrate, generate).", true),
                mk("semgrep",    Binary, "Static analysis for security findings.", false),
                mk("gitleaks",   Binary, "Scan repo for committed secrets.", false),
                mk("trivy",      Binary, "Container / dependency CVE scan.", false),
                mk("nmap",       Binary, "Network scanner.", true),
                mk("playwright", Binary, "Browser end-to-end tests.", true),
                mk("vite",       Binary, "Vite dev server.", true),
            ],
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = &ToolDef> { self.tools.iter() }

    pub fn get(&self, name: &str) -> Option<&ToolDef> {
        self.tools.iter().find(|t| t.name == name)
    }

    /// Returns the subset of tools whose name appears in `allowed`.
    pub fn intersect<'a>(&'a self, allowed: &'a [String]) -> impl Iterator<Item = &'a ToolDef> {
        self.tools.iter().filter(move |t| allowed.iter().any(|a| a == &t.name))
    }
}

impl Default for ToolRegistry {
    fn default() -> Self { Self::with_defaults() }
}
