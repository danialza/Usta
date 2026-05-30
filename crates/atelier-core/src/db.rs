//! SQLite storage layer. Single Connection guarded by a Mutex — sufficient
//! for daemon scale. All blocking calls are wrapped at call sites via
//! `tokio::task::spawn_blocking`.

use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

fn vec_f32_to_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}

fn bytes_to_vec_f32(b: &[u8]) -> Vec<f32> {
    let n = b.len() / 4;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let mut buf = [0u8; 4];
        buf.copy_from_slice(&b[i * 4..i * 4 + 4]);
        out.push(f32::from_le_bytes(buf));
    }
    out
}

fn norm(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

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
    agent_role      TEXT NOT NULL DEFAULT '',
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    created_unix_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_terms_ws ON terminals(workspace_id);
CREATE INDEX IF NOT EXISTS idx_chat_term ON chat_messages(terminal_id);
CREATE INDEX IF NOT EXISTS idx_chat_agent ON chat_messages(workspace_id, agent_role, id);

CREATE TABLE IF NOT EXISTS chunks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id    TEXT NOT NULL,
    path            TEXT NOT NULL,
    start_line      INTEGER NOT NULL,
    end_line        INTEGER NOT NULL,
    content         TEXT NOT NULL,
    embedding       BLOB NOT NULL,
    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chunks_ws ON chunks(workspace_id);
CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(workspace_id, path);

CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id    TEXT NOT NULL,
    from_role       TEXT NOT NULL,
    topic           TEXT NOT NULL,
    summary         TEXT NOT NULL,
    created_unix_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_ws ON events(workspace_id, id);
CREATE INDEX IF NOT EXISTS idx_events_topic ON events(workspace_id, topic);
"#;

#[derive(Debug, Clone)]
pub struct WorkspaceRow {
    pub id: String,
    pub path: String,
    pub name: String,
    pub opened_unix_ms: i64,
}

#[derive(Debug, Clone)]
pub struct ChatMsgRow {
    pub agent_role: String,
    pub role: String,    // "user" | "assistant"
    pub content: String,
    pub created_unix_ms: i64,
}

#[derive(Debug, Clone)]
pub struct EventRow {
    pub id: i64,
    pub workspace_id: String,
    pub from_role: String,
    pub topic: String,
    pub summary: String,
    pub created_unix_ms: i64,
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
        let conn = match Self::open_inner(&path) {
            Ok(c) => c,
            Err(e) => {
                // Corrupt / incompatible DB: back it up and start fresh rather
                // than crashing the daemon on launch.
                tracing::warn!(error = %e, "db open failed; recreating");
                let bak = path.with_extension(format!("db.bak.{}", now_unix()));
                let _ = std::fs::rename(&path, &bak);
                let _ = std::fs::remove_file(path.with_extension("db-wal"));
                let _ = std::fs::remove_file(path.with_extension("db-shm"));
                Self::open_inner(&path)?
            }
        };
        Ok(Self { conn: Mutex::new(conn), path })
    }

    fn open_inner(path: &Path) -> rusqlite::Result<Connection> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        conn.execute_batch(SCHEMA)?;
        // Migration: add agent_role to pre-existing chat_messages tables.
        let _ = conn.execute(
            "ALTER TABLE chat_messages ADD COLUMN agent_role TEXT NOT NULL DEFAULT ''",
            [],
        );
        Ok(conn)
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

    pub fn delete_workspace(&self, id: &str) -> rusqlite::Result<usize> {
        self.conn.lock().unwrap().execute(
            "DELETE FROM workspaces WHERE id = ?1",
            params![id],
        )
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

    // --- Chunks / embeddings ---

    pub fn clear_index(&self, workspace_id: &str) -> rusqlite::Result<usize> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM chunks WHERE workspace_id = ?1",
            params![workspace_id],
        )
    }

    pub fn insert_chunk(
        &self,
        workspace_id: &str,
        path: &str,
        start_line: u32,
        end_line: u32,
        content: &str,
        embedding: &[f32],
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        let blob = vec_f32_to_bytes(embedding);
        conn.execute(
            "INSERT INTO chunks (workspace_id, path, start_line, end_line, content, embedding)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![workspace_id, path, start_line, end_line, content, blob],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn chunk_count(&self, workspace_id: &str) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM chunks WHERE workspace_id = ?1",
            params![workspace_id],
            |r| r.get::<_, i64>(0),
        )
    }

    /// Brute-force cosine top-k. Fine up to ~50k chunks; swap for sqlite-vec
    /// later if needed.
    pub fn cosine_topk(
        &self,
        workspace_id: &str,
        query: &[f32],
        k: usize,
    ) -> rusqlite::Result<Vec<(String, u32, u32, String, f32)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT path, start_line, end_line, content, embedding
             FROM chunks WHERE workspace_id = ?1",
        )?;
        let q_norm = norm(query).max(1e-9);

        let mut heap: Vec<(f32, String, u32, u32, String)> = Vec::new();

        let mut rows = stmt.query(params![workspace_id])?;
        while let Some(r) = rows.next()? {
            let path: String = r.get(0)?;
            let start: u32 = r.get::<_, i64>(1)? as u32;
            let end: u32 = r.get::<_, i64>(2)? as u32;
            let content: String = r.get(3)?;
            let blob: Vec<u8> = r.get(4)?;
            let vec = bytes_to_vec_f32(&blob);
            if vec.len() != query.len() {
                continue;
            }
            let n = norm(&vec).max(1e-9);
            let mut dot = 0f32;
            for (a, b) in query.iter().zip(vec.iter()) {
                dot += a * b;
            }
            let score = dot / (q_norm * n);
            heap.push((score, path, start, end, content));
        }
        heap.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        heap.truncate(k);
        Ok(heap
            .into_iter()
            .map(|(s, p, st, en, c)| (p, st, en, c, s))
            .collect())
    }

    // --- Per-assistant chat history ---

    pub fn insert_agent_msg(
        &self,
        workspace_id: &str,
        agent_role: &str,
        role: &str,
        content: &str,
        now: i64,
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO chat_messages (workspace_id, agent_role, role, content, created_unix_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![workspace_id, agent_role, role, content, now],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn list_agent_history(
        &self,
        workspace_id: &str,
        agent_role: &str,
        limit: usize,
    ) -> rusqlite::Result<Vec<ChatMsgRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT agent_role, role, content, created_unix_ms
             FROM chat_messages
             WHERE workspace_id = ?1 AND agent_role = ?2
             ORDER BY id ASC LIMIT ?3",
        )?;
        let rows = stmt
            .query_map(params![workspace_id, agent_role, limit as i64], |r| {
                Ok(ChatMsgRow {
                    agent_role: r.get(0)?,
                    role: r.get(1)?,
                    content: r.get(2)?,
                    created_unix_ms: r.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // --- Events (inter-agent bus) ---

    pub fn insert_event(
        &self,
        workspace_id: &str,
        from_role: &str,
        topic: &str,
        summary: &str,
        now: i64,
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO events (workspace_id, from_role, topic, summary, created_unix_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![workspace_id, from_role, topic, summary, now],
        )?;
        Ok(conn.last_insert_rowid())
    }

    /// Recent events for a workspace, optionally filtered to a set of topics.
    /// `after_id` returns only events with id > after_id (0 = all). Newest last.
    pub fn list_events(
        &self,
        workspace_id: &str,
        topics: &[String],
        after_id: i64,
        limit: usize,
    ) -> rusqlite::Result<Vec<EventRow>> {
        let conn = self.conn.lock().unwrap();
        let map = |r: &rusqlite::Row| {
            Ok(EventRow {
                id: r.get(0)?,
                workspace_id: r.get(1)?,
                from_role: r.get(2)?,
                topic: r.get(3)?,
                summary: r.get(4)?,
                created_unix_ms: r.get(5)?,
            })
        };
        let mut rows: Vec<EventRow> = Vec::new();
        if topics.is_empty() {
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, from_role, topic, summary, created_unix_ms
                 FROM events WHERE workspace_id = ?1 AND id > ?2
                 ORDER BY id DESC LIMIT ?3",
            )?;
            let it = stmt.query_map(params![workspace_id, after_id, limit as i64], map)?;
            for row in it {
                rows.push(row?);
            }
        } else {
            let placeholders = topics.iter().map(|_| "?").collect::<Vec<_>>().join(",");
            let sql = format!(
                "SELECT id, workspace_id, from_role, topic, summary, created_unix_ms
                 FROM events WHERE workspace_id = ?1 AND id > ?2 AND topic IN ({placeholders})
                 ORDER BY id DESC LIMIT {limit}"
            );
            let mut stmt = conn.prepare(&sql)?;
            let mut params_vec: Vec<&dyn rusqlite::ToSql> = vec![&workspace_id, &after_id];
            for t in topics { params_vec.push(t); }
            let it = stmt.query_map(params_vec.as_slice(), map)?;
            for row in it {
                rows.push(row?);
            }
        }
        rows.reverse(); // newest last
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
