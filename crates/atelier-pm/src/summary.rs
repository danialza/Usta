//! Lightweight workspace summary: directory tree (capped) + key manifest files
//! + README. Intentionally small so it fits in a single prompt.

use ignore::WalkBuilder;
use std::fmt::Write;
use std::path::{Path, PathBuf};

const MAX_TREE_ENTRIES: usize = 200;
const MAX_TREE_DEPTH: usize = 3;
const MAX_MANIFEST_BYTES: usize = 8 * 1024;
const MAX_README_BYTES: usize = 6 * 1024;

const MANIFEST_NAMES: &[&str] = &[
    "Cargo.toml",
    "package.json",
    "pnpm-workspace.yaml",
    "pyproject.toml",
    "requirements.txt",
    "Pipfile",
    "go.mod",
    "Gemfile",
    "composer.json",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "Dockerfile",
    "docker-compose.yml",
    "docker-compose.yaml",
    "Makefile",
    "fly.toml",
    "vercel.json",
    "next.config.js",
    "next.config.mjs",
    "tsconfig.json",
    "prisma/schema.prisma",
];

const SKIP_DIRS: &[&str] = &[
    "target", "node_modules", "dist", "build", ".git", ".next",
    ".cache", ".venv", "__pycache__", "vendor",
];

pub struct WorkspaceSummary {
    pub root: PathBuf,
    pub tree: Vec<String>, // relative paths
    pub truncated_tree: bool,
    pub manifests: Vec<(String, String)>, // (rel path, content)
    pub readme: Option<(String, String)>,
}

impl WorkspaceSummary {
    pub fn render(&self) -> String {
        let mut out = String::new();
        writeln!(&mut out, "## File tree (top {}, depth ≤ {}):", MAX_TREE_ENTRIES, MAX_TREE_DEPTH).ok();
        for p in &self.tree {
            writeln!(&mut out, "  {p}").ok();
        }
        if self.truncated_tree {
            writeln!(&mut out, "  … (truncated)").ok();
        }

        if let Some((p, c)) = &self.readme {
            writeln!(&mut out, "\n## README ({p}):\n{c}").ok();
        }

        for (p, c) in &self.manifests {
            writeln!(&mut out, "\n## {p}:\n```\n{c}\n```").ok();
        }
        out
    }
}

pub fn summarize(root: &Path) -> anyhow::Result<WorkspaceSummary> {
    let mut tree = Vec::new();
    let mut truncated_tree = false;
    let mut manifests = Vec::new();
    let mut readme = None;

    let walker = WalkBuilder::new(root)
        .standard_filters(true)
        .max_depth(Some(MAX_TREE_DEPTH))
        .filter_entry(|e| {
            let n = e.file_name().to_string_lossy();
            !SKIP_DIRS.iter().any(|d| n == *d)
        })
        .build();

    for res in walker {
        let ent = match res {
            Ok(e) => e,
            Err(_) => continue,
        };
        let rel = match ent.path().strip_prefix(root) {
            Ok(r) => r.to_string_lossy().into_owned(),
            Err(_) => continue,
        };
        if rel.is_empty() { continue; }

        if ent.file_type().map(|ft| ft.is_file()).unwrap_or(false) {
            if tree.len() < MAX_TREE_ENTRIES {
                tree.push(rel.clone());
            } else {
                truncated_tree = true;
            }
            // README capture (first match wins)
            let lower = rel.to_lowercase();
            if readme.is_none() && (lower == "readme.md" || lower == "readme") {
                if let Ok(c) = read_capped(ent.path(), MAX_README_BYTES) {
                    readme = Some((rel.clone(), c));
                }
            }
            // Manifest capture
            if MANIFEST_NAMES.iter().any(|m| rel == *m || rel.ends_with(m)) {
                if let Ok(c) = read_capped(ent.path(), MAX_MANIFEST_BYTES) {
                    manifests.push((rel, c));
                }
            }
        } else if ent.file_type().map(|ft| ft.is_dir()).unwrap_or(false) {
            if tree.len() < MAX_TREE_ENTRIES {
                tree.push(format!("{rel}/"));
            } else {
                truncated_tree = true;
            }
        }
    }

    tree.sort();

    Ok(WorkspaceSummary {
        root: root.to_path_buf(),
        tree,
        truncated_tree,
        manifests,
        readme,
    })
}

fn read_capped(path: &Path, cap: usize) -> anyhow::Result<String> {
    let bytes = std::fs::read(path)?;
    let take = bytes.len().min(cap);
    let trimmed = &bytes[..take];
    let s = String::from_utf8_lossy(trimmed).into_owned();
    if bytes.len() > cap {
        Ok(format!("{s}\n... (truncated, {} bytes total)", bytes.len()))
    } else {
        Ok(s)
    }
}
