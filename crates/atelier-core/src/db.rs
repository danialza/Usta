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
    role            TEXT NOT NULL DEFAULT '',
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
    created_unix_ms INTEGER NOT NULL,
    files_changed   TEXT NOT NULL DEFAULT ''   -- newline-separated paths
);

CREATE INDEX IF NOT EXISTS idx_events_ws ON events(workspace_id, id);
CREATE INDEX IF NOT EXISTS idx_events_topic ON events(workspace_id, topic);

-- Persisted pty output for crash/restart replay. One row per ~64KB chunk.
CREATE TABLE IF NOT EXISTS term_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    terminal_id     TEXT NOT NULL,
    data            BLOB NOT NULL,
    created_unix_ms INTEGER NOT NULL,
    FOREIGN KEY (terminal_id) REFERENCES terminals(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_term_log_tid ON term_log(terminal_id, id);
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
    pub files_changed: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct TerminalRow {
    pub id: String,
    pub workspace_id: String,
    pub shell: String,
    pub cwd: String,
    pub created_unix_ms: i64,
    pub closed_unix_ms: Option<i64>,
    pub role: String,
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
        // Migration: add role to pre-existing terminals tables.
        let _ = conn.execute(
            "ALTER TABLE terminals ADD COLUMN role TEXT NOT NULL DEFAULT ''",
            [],
        );
        // Migration: add files_changed to pre-existing events tables.
        let _ = conn.execute(
            "ALTER TABLE events ADD COLUMN files_changed TEXT NOT NULL DEFAULT ''",
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
            "INSERT INTO terminals (id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms, role)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                t.id,
                t.workspace_id,
                t.shell,
                t.cwd,
                t.created_unix_ms,
                t.closed_unix_ms,
                t.role
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
                "SELECT id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms, role
                 FROM terminals WHERE workspace_id = ?1 ORDER BY created_unix_ms DESC",
                Some(w.to_string()),
            ),
            None => (
                "SELECT id, workspace_id, shell, cwd, created_unix_ms, closed_unix_ms, role
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
                role: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
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

    /// Append a chunk of pty output for replay across restarts.
    pub fn append_term_log(&self, terminal_id: &str, data: &[u8], now: i64) -> rusqlite::Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO term_log (terminal_id, data, created_unix_ms) VALUES (?1, ?2, ?3)",
            params![terminal_id, data, now],
        )?;
        Ok(())
    }

    /// Concatenated pty output for a terminal, capped to last `max_bytes`.
    pub fn read_term_log(&self, terminal_id: &str, max_bytes: usize) -> rusqlite::Result<Vec<u8>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT data FROM term_log WHERE terminal_id = ?1 ORDER BY id ASC",
        )?;
        let rows = stmt.query_map(params![terminal_id], |r| r.get::<_, Vec<u8>>(0))?;
        let mut all: Vec<u8> = Vec::new();
        for row in rows { all.extend_from_slice(&row?); }
        if all.len() > max_bytes {
            let drop_n = all.len() - max_bytes;
            all.drain(..drop_n);
        }
        Ok(all)
    }

    /// Most recent terminal id for a (workspace, role) pair, if any.
    /// Used to preload pty history into a freshly spawned session after
    /// daemon restart.
    pub fn previous_terminal_id(&self, workspace_id: &str, role: &str) -> rusqlite::Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id FROM terminals
             WHERE workspace_id = ?1 AND role = ?2
             ORDER BY created_unix_ms DESC LIMIT 1",
        )?;
        let mut rows = stmt.query_map(params![workspace_id, role], |r| r.get::<_, String>(0))?;
        if let Some(r) = rows.next() { Ok(Some(r?)) } else { Ok(None) }
    }

    pub fn insert_event(
        &self,
        workspace_id: &str,
        from_role: &str,
        topic: &str,
        summary: &str,
        now: i64,
        files: &[String],
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        let files_blob = files.join("\n");
        conn.execute(
            "INSERT INTO events (workspace_id, from_role, topic, summary, created_unix_ms, files_changed)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![workspace_id, from_role, topic, summary, now, files_blob],
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
            let blob: String = r.get::<_, Option<String>>(6)?.unwrap_or_default();
            let files = blob.split('\n').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect();
            Ok(EventRow {
                id: r.get(0)?,
                workspace_id: r.get(1)?,
                from_role: r.get(2)?,
                topic: r.get(3)?,
                summary: r.get(4)?,
                created_unix_ms: r.get(5)?,
                files_changed: files,
            })
        };
        let mut rows: Vec<EventRow> = Vec::new();
        if topics.is_empty() {
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, from_role, topic, summary, created_unix_ms, files_changed
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
                "SELECT id, workspace_id, from_role, topic, summary, created_unix_ms, files_changed
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_db() -> Db {
        let p = std::env::temp_dir().join(format!("atelier-test-{}.db", uuid::Uuid::new_v4().simple()));
        Db::open(&p).expect("open db")
    }

    fn seed_ws_and_term(db: &Db, ws: &str, role: &str) -> String {
        db.upsert_workspace(&WorkspaceRow {
            id: ws.into(), path: format!("/tmp/{ws}"), name: ws.into(), opened_unix_ms: 1,
        }).unwrap();
        let tid = format!("t_{role}");
        db.insert_terminal(&TerminalRow {
            id: tid.clone(), workspace_id: ws.into(), shell: "zsh".into(),
            cwd: format!("/tmp/{ws}"), created_unix_ms: 10, closed_unix_ms: None,
            role: role.into(),
        }).unwrap();
        tid
    }

    #[test]
    fn schema_applies_and_is_idempotent() {
        // open() runs SCHEMA + ALTER migrations. Re-running open_inner on the
        // same file must not error (ALTERs are best-effort, CREATEs IF NOT EXISTS).
        let p = std::env::temp_dir().join(format!("atelier-idem-{}.db", uuid::Uuid::new_v4().simple()));
        let _a = Db::open(&p).expect("first open");
        let _b = Db::open(&p).expect("second open (idempotent)");
    }

    #[test]
    fn term_log_roundtrip_and_cap() {
        let db = tmp_db();
        let tid = seed_ws_and_term(&db, "ws1", "backend");
        db.append_term_log(&tid, b"hello ", 1).unwrap();
        db.append_term_log(&tid, b"world", 2).unwrap();
        let all = db.read_term_log(&tid, 1024).unwrap();
        assert_eq!(all, b"hello world");
        // Cap keeps the tail.
        let capped = db.read_term_log(&tid, 5).unwrap();
        assert_eq!(capped, b"world");
    }

    #[test]
    fn previous_terminal_id_picks_latest() {
        let db = tmp_db();
        db.upsert_workspace(&WorkspaceRow {
            id: "ws2".into(), path: "/tmp/ws2".into(), name: "ws2".into(), opened_unix_ms: 1,
        }).unwrap();
        for (i, t) in ["old", "new"].iter().enumerate() {
            db.insert_terminal(&TerminalRow {
                id: format!("t_{t}"), workspace_id: "ws2".into(), shell: "zsh".into(),
                cwd: "/tmp/ws2".into(), created_unix_ms: (i as i64) * 100,
                closed_unix_ms: None, role: "frontend".into(),
            }).unwrap();
        }
        let prev = db.previous_terminal_id("ws2", "frontend").unwrap();
        assert_eq!(prev, Some("t_new".into()));
        assert_eq!(db.previous_terminal_id("ws2", "nobody").unwrap(), None);
    }

    #[test]
    fn events_persist_files_changed() {
        let db = tmp_db();
        db.upsert_workspace(&WorkspaceRow {
            id: "ws3".into(), path: "/tmp/ws3".into(), name: "ws3".into(), opened_unix_ms: 1,
        }).unwrap();
        let files = vec!["src/a.rs".to_string(), "src/b.rs".to_string()];
        db.insert_event("ws3", "backend", "api.contract.defined", "spec", 5, &files).unwrap();
        let rows = db.list_events("ws3", &[], 0, 50).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].files_changed, files);
        assert_eq!(rows[0].topic, "api.contract.defined");
    }

    #[test]
    fn list_events_filters_by_topic() {
        let db = tmp_db();
        db.upsert_workspace(&WorkspaceRow {
            id: "ws4".into(), path: "/tmp/ws4".into(), name: "ws4".into(), opened_unix_ms: 1,
        }).unwrap();
        db.insert_event("ws4", "a", "topic.one", "s1", 1, &[]).unwrap();
        db.insert_event("ws4", "b", "topic.two", "s2", 2, &[]).unwrap();
        let only = db.list_events("ws4", &["topic.two".to_string()], 0, 50).unwrap();
        assert_eq!(only.len(), 1);
        assert_eq!(only[0].from_role, "b");
    }
}
