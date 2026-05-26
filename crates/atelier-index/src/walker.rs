//! Gitignore-aware file walker. Filters by size and extension.

use ignore::WalkBuilder;
use std::path::{Path, PathBuf};

const MAX_FILE_BYTES: u64 = 1024 * 1024; // 1 MB

/// Hard skips on top of .gitignore: build artifacts and lockfiles we don't care
/// about for search relevance.
const SKIP_DIRS: &[&str] = &[
    "target", "node_modules", "dist", "build", ".git", ".next", ".cache", ".venv",
    "__pycache__", ".idea", ".vscode", ".DS_Store", "vendor",
];

pub fn walk(root: &Path) -> impl Iterator<Item = PathBuf> {
    let walker = WalkBuilder::new(root)
        .standard_filters(true) // respects .gitignore, .ignore, hidden
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            !SKIP_DIRS.iter().any(|d| name == *d)
        })
        .build();

    walker.filter_map(|res| {
        let ent = res.ok()?;
        let ft = ent.file_type()?;
        if !ft.is_file() {
            return None;
        }
        let meta = ent.metadata().ok()?;
        if meta.len() > MAX_FILE_BYTES || meta.len() == 0 {
            return None;
        }
        Some(ent.into_path())
    })
}
