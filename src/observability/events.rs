use std::io::Write;
use std::path::PathBuf;

use crate::db::Database;
use crate::types::Event;

/// Dual-write an event to both SQLite and JSONL (backward compatibility)
pub fn emit_event(db: &Database, events_path: &PathBuf, event: &Event) {
    // Write to SQLite
    if let Err(e) = db.insert_event(event) {
        tracing::warn!("Failed to write event to SQLite: {}", e);
    }

    // Write to JSONL (backward compatibility for Loki filelog receiver)
    if let Ok(json) = serde_json::to_string(event) {
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(events_path)
        {
            let _ = writeln!(f, "{}", json);
        }
    }
}

/// Create a standard event with session context
pub fn make_event(event_type: &str, tool: &str, session_id: Option<&str>) -> Event {
    let start_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    let mut event = Event::new(event_type, tool);
    event.timestamp = start_time;
    event.session_id = session_id.map(String::from);
    event
}
