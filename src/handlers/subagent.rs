use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle_start(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let agent_id = input
        .agent_id
        .as_deref()
        .unwrap_or("unknown");
    let agent_type = input
        .agent_type
        .as_deref()
        .unwrap_or("unknown");

    let _ = state
        .db
        .start_subagent(agent_id, session_id, agent_type);

    let mut event = events::make_event("subagent_start", "", Some(session_id));
    let mut extra = serde_json::Map::new();
    extra.insert(
        "agent_id".into(),
        serde_json::Value::String(agent_id.to_string()),
    );
    extra.insert(
        "agent_type".into(),
        serde_json::Value::String(agent_type.to_string()),
    );
    event.extra = Some(extra);
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}

pub fn handle_stop(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let agent_id = input
        .agent_id
        .as_deref()
        .unwrap_or("unknown");

    // Get final stats before marking stopped
    let (call_count, cumulative_bytes) = state
        .db
        .get_subagent_stats(agent_id)
        .unwrap_or((0, 0));

    let _ = state.db.stop_subagent(agent_id);

    let mut event = events::make_event("subagent_stop", "", Some(session_id));
    let mut extra = serde_json::Map::new();
    extra.insert(
        "agent_id".into(),
        serde_json::Value::String(agent_id.to_string()),
    );
    extra.insert(
        "call_count".into(),
        serde_json::Value::Number(call_count.into()),
    );
    extra.insert(
        "cumulative_bytes".into(),
        serde_json::Value::Number(cumulative_bytes.into()),
    );
    event.extra = Some(extra);
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}
