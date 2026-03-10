use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    // Log compaction event with session stats
    let tool_count = state.db.get_session_tool_count(session_id).unwrap_or(0);
    let tokens_saved = state.db.sum_tokens_saved(session_id).unwrap_or(0);

    let mut event = events::make_event("pre_compact", "", Some(session_id));
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

    // Add context about session savings
    if tokens_saved > 0 {
        let msg = format!(
            "Session stats before compaction: {} tool calls, ~{} tokens saved by warden",
            tool_count, tokens_saved
        );
        return HookOutput::additional_context("PreCompact", &msg);
    }

    HookOutput::passthrough()
}
