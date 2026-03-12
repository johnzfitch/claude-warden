use anyhow::Result;
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Mutex;

use crate::types::BudgetInfo;

pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let conn = Connection::open(path)?;

        // Configure WAL mode and pragmas
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA synchronous = NORMAL;",
        )?;

        // Run migrations
        Self::migrate(&conn)?;

        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Open an in-memory database (for testing)
    pub fn open_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA journal_mode = WAL;")?;
        Self::migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn migrate(conn: &Connection) -> Result<()> {
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS budget (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                consumed INTEGER NOT NULL DEFAULT 0,
                total_limit INTEGER NOT NULL DEFAULT 280000,
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            INSERT OR IGNORE INTO budget (id) VALUES (1);

            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                started_at INTEGER NOT NULL,
                started_at_ns TEXT,
                ended_at INTEGER,
                tool_count INTEGER NOT NULL DEFAULT 0,
                top_output_bytes INTEGER NOT NULL DEFAULT 0,
                top_output_label TEXT NOT NULL DEFAULT '',
                cwd TEXT,
                budget_at_start INTEGER NOT NULL DEFAULT 0,
                budget_at_end INTEGER
            );

            CREATE TABLE IF NOT EXISTS subagents (
                agent_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                agent_type TEXT NOT NULL DEFAULT '',
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                call_count INTEGER NOT NULL DEFAULT 0,
                cumulative_bytes INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'running'
            );

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp_rel REAL NOT NULL,
                event_type TEXT NOT NULL,
                tool TEXT,
                session_id TEXT,
                original_cmd TEXT,
                tokens_saved INTEGER DEFAULT 0,
                original_output_bytes INTEGER DEFAULT 0,
                final_output_bytes INTEGER DEFAULT 0,
                rule TEXT,
                extra TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
            CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);

            CREATE TABLE IF NOT EXISTS tool_timing (
                tool_use_id TEXT PRIMARY KEY,
                tool_name TEXT NOT NULL,
                session_id TEXT,
                started_at_ns INTEGER,
                ended_at_ns INTEGER,
                duration_ms INTEGER,
                command TEXT
            );

            CREATE TABLE IF NOT EXISTS quiet_overrides (
                tool_use_id TEXT PRIMARY KEY,
                rule TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            ",
        )?;
        Ok(())
    }

    // === Budget ===

    pub fn get_budget(&self) -> Result<BudgetInfo> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT consumed, total_limit FROM budget WHERE id = 1")?;
        let result = stmt.query_row([], |row| {
            let consumed: i64 = row.get(0)?;
            let total_limit: i64 = row.get(1)?;
            Ok(BudgetInfo {
                consumed,
                total_limit,
                remaining: total_limit - consumed,
                percentage_used: if total_limit > 0 {
                    (consumed as f64 / total_limit as f64) * 100.0
                } else {
                    0.0
                },
            })
        })?;
        Ok(result)
    }

    pub fn update_budget(&self, consumed: i64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE budget SET consumed = ?, updated_at = strftime('%s', 'now') WHERE id = 1",
            params![consumed],
        )?;
        Ok(())
    }

    pub fn set_budget_limit(&self, total: i64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE budget SET total_limit = ?, updated_at = strftime('%s', 'now') WHERE id = 1",
            params![total],
        )?;
        Ok(())
    }

    // === Sessions ===

    pub fn start_session(&self, session_id: &str, cwd: Option<&str>) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp();
        let now_ns = chrono::Utc::now().timestamp_nanos_opt().map(|n| n.to_string());
        let budget = conn
            .query_row("SELECT consumed FROM budget WHERE id = 1", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(0);

        conn.execute(
            "INSERT OR REPLACE INTO sessions (session_id, started_at, started_at_ns, cwd, budget_at_start)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![session_id, now, now_ns, cwd, budget],
        )?;
        Ok(())
    }

    pub fn end_session(&self, session_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp();
        let budget = conn
            .query_row("SELECT consumed FROM budget WHERE id = 1", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(0);

        conn.execute(
            "UPDATE sessions SET ended_at = ?1, budget_at_end = ?2 WHERE session_id = ?3",
            params![now, budget, session_id],
        )?;

        // Cleanup stale data
        conn.execute_batch(
            "DELETE FROM tool_timing WHERE started_at_ns < (strftime('%s','now') - 86400) * 1000000000;
             DELETE FROM quiet_overrides WHERE created_at < strftime('%s','now') - 3600;",
        )?;
        Ok(())
    }

    pub fn increment_tool_count(&self, session_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET tool_count = tool_count + 1 WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(())
    }

    pub fn get_session_tool_count(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let count = conn
            .query_row(
                "SELECT tool_count FROM sessions WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(count)
    }

    // === Subagents ===

    pub fn start_subagent(
        &self,
        agent_id: &str,
        session_id: &str,
        agent_type: &str,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "INSERT OR REPLACE INTO subagents (agent_id, session_id, agent_type, started_at, status)
             VALUES (?1, ?2, ?3, ?4, 'running')",
            params![agent_id, session_id, agent_type, now],
        )?;
        Ok(())
    }

    pub fn stop_subagent(&self, agent_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "UPDATE subagents SET ended_at = ?1, status = 'stopped' WHERE agent_id = ?2",
            params![now, agent_id],
        )?;
        Ok(())
    }

    pub fn add_subagent_bytes(&self, agent_id: &str, bytes: i64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE subagents SET cumulative_bytes = cumulative_bytes + ?1, call_count = call_count + 1 WHERE agent_id = ?2",
            params![bytes, agent_id],
        )?;
        Ok(())
    }

    pub fn get_subagent_stats(&self, agent_id: &str) -> Result<(i64, i64)> {
        let conn = self.conn.lock().unwrap();
        let result = conn.query_row(
            "SELECT call_count, cumulative_bytes FROM subagents WHERE agent_id = ?1",
            params![agent_id],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        );
        Ok(result.unwrap_or((0, 0)))
    }

    pub fn count_active_subagents(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let count = conn
            .query_row(
                "SELECT COUNT(*) FROM subagents WHERE session_id = ?1 AND status = 'running'",
                params![session_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(count)
    }

    pub fn count_all_active_subagents(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let count = conn
            .query_row(
                "SELECT COUNT(*) FROM subagents WHERE status = 'running'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(count)
    }

    // === Events ===

    pub fn insert_event(&self, event: &crate::types::Event) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let extra = event
            .extra
            .as_ref()
            .map(|e| serde_json::to_string(e).unwrap_or_default());
        conn.execute(
            "INSERT INTO events (timestamp_rel, event_type, tool, session_id, original_cmd, tokens_saved, original_output_bytes, final_output_bytes, rule, extra)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                event.timestamp,
                event.event_type,
                event.tool,
                event.session_id,
                event.original_cmd,
                event.tokens_saved,
                event.original_output_bytes,
                event.final_output_bytes,
                event.rule,
                extra,
            ],
        )?;
        Ok(())
    }

    pub fn sum_tokens_saved(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let sum = conn
            .query_row(
                "SELECT COALESCE(SUM(tokens_saved), 0) FROM events WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(sum)
    }

    // === Tool Timing ===

    pub fn record_tool_start(
        &self,
        tool_use_id: &str,
        tool_name: &str,
        session_id: &str,
        command: &str,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now_ns = chrono::Utc::now()
            .timestamp_nanos_opt()
            .unwrap_or(0);
        conn.execute(
            "INSERT OR REPLACE INTO tool_timing (tool_use_id, tool_name, session_id, started_at_ns, command)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![tool_use_id, tool_name, session_id, now_ns, command],
        )?;
        Ok(())
    }

    pub fn record_tool_end(&self, tool_use_id: &str) -> Result<Option<i64>> {
        let conn = self.conn.lock().unwrap();
        let now_ns = chrono::Utc::now()
            .timestamp_nanos_opt()
            .unwrap_or(0);

        let start_ns: Option<i64> = conn
            .query_row(
                "SELECT started_at_ns FROM tool_timing WHERE tool_use_id = ?1",
                params![tool_use_id],
                |row| row.get(0),
            )
            .ok();

        if let Some(start) = start_ns {
            let duration_ms = (now_ns - start) / 1_000_000;
            conn.execute(
                "UPDATE tool_timing SET ended_at_ns = ?1, duration_ms = ?2 WHERE tool_use_id = ?3",
                params![now_ns, duration_ms, tool_use_id],
            )?;
            Ok(Some(duration_ms))
        } else {
            Ok(None)
        }
    }

    pub fn last_tool_latency(&self, session_id: &str) -> Option<i64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT duration_ms FROM tool_timing WHERE session_id = ?1 AND duration_ms IS NOT NULL ORDER BY ended_at_ns DESC LIMIT 1",
            params![session_id],
            |row| row.get(0),
        ).ok()
    }

    // === Quiet Overrides ===

    pub fn insert_quiet_override(&self, tool_use_id: &str, rule: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO quiet_overrides (tool_use_id, rule) VALUES (?1, ?2)",
            params![tool_use_id, rule],
        )?;
        Ok(())
    }

    pub fn take_quiet_override(&self, tool_use_id: &str) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let rule: Option<String> = conn
            .query_row(
                "SELECT rule FROM quiet_overrides WHERE tool_use_id = ?1",
                params![tool_use_id],
                |row| row.get(0),
            )
            .ok();

        if rule.is_some() {
            conn.execute(
                "DELETE FROM quiet_overrides WHERE tool_use_id = ?1",
                params![tool_use_id],
            )?;
        }
        Ok(rule)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_budget_operations() {
        let db = Database::open_memory().unwrap();
        let budget = db.get_budget().unwrap();
        assert_eq!(budget.consumed, 0);
        assert_eq!(budget.total_limit, 280000);

        db.update_budget(1000).unwrap();
        let budget = db.get_budget().unwrap();
        assert_eq!(budget.consumed, 1000);
        assert_eq!(budget.remaining, 279000);
    }

    #[test]
    fn test_quiet_override_isolation() {
        let db = Database::open_memory().unwrap();

        db.insert_quiet_override("tool-use-1", "git_commit")
            .unwrap();
        db.insert_quiet_override("tool-use-2", "npm_install")
            .unwrap();

        // Each tool_use_id gets its own rule
        let rule1 = db.take_quiet_override("tool-use-1").unwrap();
        assert_eq!(rule1, Some("git_commit".to_string()));

        let rule2 = db.take_quiet_override("tool-use-2").unwrap();
        assert_eq!(rule2, Some("npm_install".to_string()));

        // Second take returns None (consumed)
        let rule1_again = db.take_quiet_override("tool-use-1").unwrap();
        assert_eq!(rule1_again, None);
    }

    #[test]
    fn test_session_lifecycle() {
        let db = Database::open_memory().unwrap();

        db.start_session("sess-1", Some("/home/user/project"))
            .unwrap();
        db.increment_tool_count("sess-1").unwrap();
        db.increment_tool_count("sess-1").unwrap();
        let count = db.get_session_tool_count("sess-1").unwrap();
        assert_eq!(count, 2);

        db.end_session("sess-1").unwrap();
    }

    #[test]
    fn test_subagent_tracking() {
        let db = Database::open_memory().unwrap();

        db.start_subagent("agent-1", "sess-1", "Explore").unwrap();
        db.add_subagent_bytes("agent-1", 5000).unwrap();
        db.add_subagent_bytes("agent-1", 3000).unwrap();

        let (calls, bytes) = db.get_subagent_stats("agent-1").unwrap();
        assert_eq!(calls, 2);
        assert_eq!(bytes, 8000);

        let active = db.count_active_subagents("sess-1").unwrap();
        assert_eq!(active, 1);

        db.stop_subagent("agent-1").unwrap();
        let active = db.count_active_subagents("sess-1").unwrap();
        assert_eq!(active, 0);
    }
}
