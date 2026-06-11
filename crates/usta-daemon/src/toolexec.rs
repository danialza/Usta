//! Workspace-scoped tool execution for agentic role chats.
//!
//! Every path is resolved inside the workspace root; escapes (.., absolute
//! paths outside root) are rejected. Destructive tools (fs_write, shell) are
//! gated by the role's PermissionPolicy.

use usta_providers::ToolSpec;
use usta_roles::{Permission, Role};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const MAX_OUTPUT: usize = 16 * 1024;

/// Build the ToolSpec list a role is allowed to use.
pub fn specs_for_role(role: &Role) -> Vec<ToolSpec> {
    let mut out = Vec::new();
    let allowed = |t: &str| role.allowed_tools.iter().any(|a| a == t);

    if allowed("fs_read") {
        out.push(ToolSpec {
            name: "fs_read".into(),
            description: "Read a UTF-8 text file inside the workspace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": { "path": { "type": "string", "description": "workspace-relative path" } },
                "required": ["path"]
            }),
        });
        out.push(ToolSpec {
            name: "list_dir".into(),
            description: "List entries of a directory inside the workspace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": { "path": { "type": "string", "description": "workspace-relative dir (default '.')" } }
            }),
        });
    }
    if allowed("fs_read") {
        out.push(ToolSpec {
            name: "grep".into(),
            description: "Search for a substring across workspace text files; returns path:line matches.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string" },
                    "path": { "type": "string", "description": "subdir to search (default '.')" }
                },
                "required": ["query"]
            }),
        });
    }
    if allowed("fs_write") {
        out.push(ToolSpec {
            name: "fs_write".into(),
            description: "Create or overwrite a UTF-8 text file inside the workspace.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "content": { "type": "string" }
                },
                "required": ["path", "content"]
            }),
        });
        out.push(ToolSpec {
            name: "fs_edit".into(),
            description: "Replace an exact string in a file with new text (a surgical patch). \
                          old_string must match exactly once.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "old_string": { "type": "string" },
                    "new_string": { "type": "string" }
                },
                "required": ["path", "old_string", "new_string"]
            }),
        });
    }
    if allowed("shell") {
        out.push(ToolSpec {
            name: "shell".into(),
            description: "Run a shell command in the workspace root and capture stdout/stderr.".into(),
            input_schema: json!({
                "type": "object",
                "properties": { "command": { "type": "string" } },
                "required": ["command"]
            }),
        });
    }
    out
}

fn perm_allows(p: Option<&Permission>, default_deny: bool) -> bool {
    // Ask is treated as allow here because approval is handled upstream in
    // the daemon (gate()); execute() only runs after the user approved.
    match p {
        Some(Permission::Allow) | Some(Permission::AllowSafe) | Some(Permission::Ask) => true,
        Some(Permission::Deny) => false,
        None => !default_deny,
    }
}

/// Approval gate decision for a tool, before execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate { Allowed, Ask, Denied }

/// Decide whether a tool needs approval / is denied, based on role perms.
/// fs_read / list_dir / grep are always allowed (read-only).
pub fn gate(role: &Role, tool: &str) -> Gate {
    let perm = match tool {
        "fs_read" | "list_dir" | "grep" => return Gate::Allowed,
        "fs_write" | "fs_edit" => role.permissions.fs_write.as_ref(),
        "shell" => role.permissions.exec.as_ref(),
        _ => None,
    };
    match perm {
        Some(Permission::Allow) | Some(Permission::AllowSafe) => Gate::Allowed,
        Some(Permission::Ask) => Gate::Ask,
        Some(Permission::Deny) => Gate::Denied,
        None => Gate::Ask, // default: ask for destructive tools
    }
}

/// Resolve a workspace-relative path, rejecting escapes.
fn resolve(root: &Path, rel: &str) -> anyhow::Result<PathBuf> {
    let candidate = if rel.is_empty() || rel == "." {
        root.to_path_buf()
    } else {
        root.join(rel)
    };
    // Normalize without touching the filesystem for non-existent paths.
    let mut normalized = PathBuf::new();
    for comp in candidate.components() {
        use std::path::Component::*;
        match comp {
            ParentDir => { normalized.pop(); }
            CurDir => {}
            other => normalized.push(other.as_os_str()),
        }
    }
    if !normalized.starts_with(root) {
        anyhow::bail!("path escapes workspace: {rel}");
    }
    Ok(normalized)
}

/// Tiny line-level diff: `-` removed, `+` added (no LCS, just block-level).
/// Good enough for surfacing what changed in a tool row.
fn simple_diff(old: &str, new: &str) -> String {
    let o: Vec<&str> = old.lines().collect();
    let n: Vec<&str> = new.lines().collect();
    // Common prefix.
    let mut start = 0;
    while start < o.len() && start < n.len() && o[start] == n[start] { start += 1; }
    // Common suffix.
    let mut o_end = o.len();
    let mut n_end = n.len();
    while o_end > start && n_end > start && o[o_end - 1] == n[n_end - 1] {
        o_end -= 1; n_end -= 1;
    }
    let mut out = String::new();
    for line in &o[start..o_end] { out.push_str(&format!("- {line}\n")); }
    for line in &n[start..n_end] { out.push_str(&format!("+ {line}\n")); }
    if out.is_empty() { out.push_str("(no line changes)"); }
    cap(out)
}

fn cap(mut s: String) -> String {
    if s.len() > MAX_OUTPUT {
        s.truncate(MAX_OUTPUT);
        s.push_str("\n…(truncated)");
    }
    s
}

/// Execute one tool call. `root` is the workspace dir; `role` gates writes/exec.
pub async fn execute(root: PathBuf, role: Role, name: String, input: Value) -> anyhow::Result<String> {
    match name.as_str() {
        "fs_read" => {
            let rel = input["path"].as_str().unwrap_or_default();
            let p = resolve(&root, rel)?;
            let bytes = tokio::fs::read(&p).await
                .map_err(|e| anyhow::anyhow!("read {}: {e}", p.display()))?;
            Ok(cap(String::from_utf8_lossy(&bytes).into_owned()))
        }
        "list_dir" => {
            let rel = input["path"].as_str().unwrap_or(".");
            let p = resolve(&root, rel)?;
            let mut rd = tokio::fs::read_dir(&p).await
                .map_err(|e| anyhow::anyhow!("list {}: {e}", p.display()))?;
            let mut lines = Vec::new();
            while let Some(ent) = rd.next_entry().await? {
                let kind = if ent.file_type().await.map(|t| t.is_dir()).unwrap_or(false) { "dir " } else { "file" };
                lines.push(format!("{kind}  {}", ent.file_name().to_string_lossy()));
            }
            lines.sort();
            Ok(cap(lines.join("\n")))
        }
        "grep" => {
            let query = input["query"].as_str().unwrap_or_default();
            if query.is_empty() { anyhow::bail!("empty query"); }
            let rel = input["path"].as_str().unwrap_or(".");
            let base = resolve(&root, rel)?;
            let out = tokio::process::Command::new("grep")
                .args(["-rIn", "--max-count=5", query])
                .arg(&base)
                .output()
                .await
                .map_err(|e| anyhow::anyhow!("grep: {e}"))?;
            let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
            // strip the workspace prefix for readability
            s = s.replace(&format!("{}/", root.display()), "");
            if s.trim().is_empty() { s = "(no matches)".into(); }
            Ok(cap(s))
        }
        "fs_write" => {
            if !perm_allows(role.permissions.fs_write.as_ref(), true) {
                anyhow::bail!("fs_write denied for role '{}' (set permissions.fs_write: allow)", role.name);
            }
            let rel = input["path"].as_str().unwrap_or_default();
            let content = input["content"].as_str().unwrap_or_default();
            let p = resolve(&root, rel)?;
            let prev = tokio::fs::read_to_string(&p).await.unwrap_or_default();
            if let Some(parent) = p.parent() { tokio::fs::create_dir_all(parent).await.ok(); }
            tokio::fs::write(&p, content).await
                .map_err(|e| anyhow::anyhow!("write {}: {e}", p.display()))?;
            let verb = if prev.is_empty() { "created" } else { "overwrote" };
            Ok(format!("{verb} {rel}\n{}", simple_diff(&prev, content)))
        }
        "fs_edit" => {
            if !perm_allows(role.permissions.fs_write.as_ref(), true) {
                anyhow::bail!("fs_edit denied for role '{}' (set permissions.fs_write: allow)", role.name);
            }
            let rel = input["path"].as_str().unwrap_or_default();
            let old = input["old_string"].as_str().unwrap_or_default();
            let new = input["new_string"].as_str().unwrap_or_default();
            if old.is_empty() { anyhow::bail!("old_string required"); }
            let p = resolve(&root, rel)?;
            let body = tokio::fs::read_to_string(&p).await
                .map_err(|e| anyhow::anyhow!("read {}: {e}", p.display()))?;
            let count = body.matches(old).count();
            if count == 0 { anyhow::bail!("old_string not found in {rel}"); }
            if count > 1 { anyhow::bail!("old_string matches {count} times in {rel}; make it unique"); }
            let patched = body.replacen(old, new, 1);
            tokio::fs::write(&p, &patched).await
                .map_err(|e| anyhow::anyhow!("write {}: {e}", p.display()))?;
            Ok(format!("edited {rel}\n{}", simple_diff(old, new)))
        }
        "shell" => {
            if !perm_allows(role.permissions.exec.as_ref(), true) {
                anyhow::bail!("shell denied for role '{}' (set permissions.exec: allow)", role.name);
            }
            let command = input["command"].as_str().unwrap_or_default();
            if command.trim().is_empty() { anyhow::bail!("empty command"); }
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
            let out = tokio::process::Command::new(shell)
                .arg("-lc")
                .arg(command)
                .current_dir(&root)
                .output()
                .await
                .map_err(|e| anyhow::anyhow!("spawn: {e}"))?;
            let mut s = String::new();
            if !out.stdout.is_empty() { s.push_str(&String::from_utf8_lossy(&out.stdout)); }
            if !out.stderr.is_empty() {
                s.push_str("\n[stderr]\n");
                s.push_str(&String::from_utf8_lossy(&out.stderr));
            }
            s.push_str(&format!("\n[exit {}]", out.status.code().unwrap_or(-1)));
            Ok(cap(s))
        }
        other => anyhow::bail!("unknown tool '{other}'"),
    }
}
