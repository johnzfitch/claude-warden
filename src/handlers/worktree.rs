use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle_create(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("worktree_create", "", Some(session_id));
    if let Some(ref name) = input.name {
        let mut extra = serde_json::Map::new();
        extra.insert(
            "worktree_name".into(),
            serde_json::Value::String(name.clone()),
        );
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    // Passthrough — WorktreeCreate has special semantics where stdout is a path.
    // For HTTP hooks, we let Claude Code's default worktree logic handle it.
    HookOutput::passthrough()
}

pub fn handle_remove(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("worktree_remove", "", Some(session_id));
    if let Some(ref name) = input.name {
        let mut extra = serde_json::Map::new();
        extra.insert(
            "worktree_name".into(),
            serde_json::Value::String(name.clone()),
        );
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::passthrough()
}
