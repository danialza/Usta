//! SQLite storage layer. Single Connection guarded by a Mutex — sufficient
//! for daemon scale. All blocking calls are wrapped at call sites via
//! `tokio::task::spawn_blocking`.

use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct Db {
    conn: Mutex<Connection>,
    pub path: PathBuf,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS workspaces (
    id              TEXT PRIMARY KEY,
    path            TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    opened_unix_ms  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS terminals (
    id              TEXT PRIMARY KEY,
    workspace_id    TEXT NOT NULL,
    shell           TEXT NOT NULL,
    cwd             TEXT NOT NULL,
    created_unix_ms INTEGER NOT NULL,
    closed_unix_ms  INTEGER,
    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    terminal_id     TEXT,
    workspace_id    TEXT,
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    created_unix_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_terms_ws ON terminals(workspace_id);
CREATE INDEX IF NOT EXISTS idx_chat_term ON chat_messages(terminal_id);
"#;

#[derive(Debug, Clone)]
pub struct WorkspaceRow {
    pub id: String,
    pub path: String,
    pub name: String,
    pub opened_unix_ms: i64,
}

#[derive(Debug, Clone)]
pub struct TerminalRow {
    pub id: String,
    pub workspace_id: String,
    pub shell: String,
    pub cwd: String,
    pub created_unix_ms: i64,
    pub closed_unix_ms: Option<i64>,
}

impl Db {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(&path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn), path })
    }

    pub fn upsert_workspace(&self, ws: &WorkspaceRow) -> rusqlite::Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO workspaces (id, path, name, opened_unix_ms)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(path) DO UPDATE SET opened_unix_ms = excluded.opened_unix_ms",
            params![ws.id, ws.path, ws.name, ws.opened_unix_ms],
        )?;
        Ok(())
    }

    pub fn list_workspaces(&self) -> rusqlite::Result<Vec<WorkspaceRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, path, name, opened_unix_ms FROM workspaces ORDER BY opened_unix_ms DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(WorkspaceRow {
                    id: r.get(0)?,
                    path: r.get(1)?,
                    name: r.get(2)?,
                    opened_unix_ms: r.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn get_workspace_by_path(&self, path: &str) -> rusqlite::Result<Option<WorkspaceRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, path, name, opened_unix_ms FROM workspaces WHERE path = ?1",
        )?;
        let mut rows = stmt.query(params![path])?;
        if let Some(r) = rows.next()? {
            Ok(Some(WorkspaceRow {
                id: r.get(0)?,
                path: r.get(1)?,
                name: r.get(2)?,
                opened_unix_ms: r.get(3)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn insert_terminal(&self, t: &TerminalRow) -> rusqlite::Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO terminals (id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                t.id,
                t.workspace_id,
                t.shell,
                t.cwd,
                t.created_unix_ms,
                t.closed_unix_ms
            ],
        )?;
        Ok(())
    }

    pub fn close_terminal(&self, id: &str, now: i64) -> rusqlite::Result<()> {
        self.conn.lock().unwrap().execute(
            "UPDATE terminals SET closed_unix_ms = ?1 WHERE id = ?2 AND closed_unix_ms IS NULL",
            params![now, id],
        )?;
        Ok(())
    }

    pub fn list_terminals(&self, workspace_id: Option<&str>) -> rusqlite::Result<Vec<TerminalRow>> {
        let conn = self.conn.lock().unwrap();
        let (sql, ws): (&str, Option<String>) = match workspace_id {
            Some(w) => (
                "SELECT id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms
                 FROM terminals WHERE workspace_id = ?1 ORDER BY created_unix_ms DESC",
                Some(w.to_string()),
            ),
            None => (
                "SELECT id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms
                 FROM terminals ORDER BY created_unix_ms DESC",
                None,
            ),
        };
        let mut stmt = conn.prepare(sql)?;
        let map = |r: &rusqlite::Row| {
            Ok(TerminalRow {
                id: r.get(0)?,
                workspace_id: r.get(1)?,
                shell: r.get(2)?,
                cwd: r.get(3)?,
                created_unix_ms: r.get(4)?,
                closed_unix_ms: r.get(5)?,
            })
        };
        let rows = if let Some(w) = ws {
            stmt.query_map(params![w], map)?.collect::<Result<Vec<_>, _>>()?
        } else {
            stmt.query_map([], map)?.collect::<Result<Vec<_>, _>>()?
        };
        Ok(rows)
    }

    pub fn insert_chat(
        &self,
        terminal_id: Option<&str>,
        workspace_id: Option<&str>,
        role: &str,
        content: &str,
        now: i64,
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO chat_messages (terminal_id, workspace_id, role, content, created_unix_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![terminal_id, workspace_id, role, content, now],
        )?;
        Ok(conn.last_insert_rowid())
    }
}
