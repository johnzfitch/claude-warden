use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle_start(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let cwd = input.cwd.as_deref();

    tracing::info!("Session started: {}", session_id);

    // Initialize session in database
    let _ = state.db.start_session(session_id, cwd);

    // Set budget limit from config
    let _ = state
        .db
        .set_budget_limit(state.config.thresholds.budget_total);

    let event = events::make_event("session_start", "", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}

pub fn handle_end(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    tracing::info!("Session ended: {}", session_id);

    // Finalize session
    let _ = state.db.end_session(session_id);

    // Get final stats for logging
    let tool_count = state.db.get_session_tool_count(session_id).unwrap_or(0);
    let tokens_saved = state.db.sum_tokens_saved(session_id).unwrap_or(0);

    let mut event = events::make_event("session_end", "", Some(session_id));
    let mut extra = serde_json::Map::new();
    extra.insert(
        "tool_count".into(),
        serde_json::Value::Number(tool_count.into()),
    );
    extra.insert(
        "tokens_saved".into(),
        serde_json::Value::Number(tokens_saved.into()),
    );
    event.extra = Some(extra);
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}
