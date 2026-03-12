use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle_idle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("teammate_idle", "", Some(session_id));
    if let Some(ref name) = input.teammate_name {
        let mut extra = serde_json::Map::new();
        extra.insert(
            "teammate_name".into(),
            serde_json::Value::String(name.clone()),
        );
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::passthrough()
}

pub fn handle_completed(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("task_completed", "", Some(session_id));
    let mut extra = serde_json::Map::new();

    if let Some(ref id) = input.task_id {
        extra.insert(
            "task_id".into(),
            serde_json::Value::String(id.clone()),
        );
    }
    if let Some(ref subject) = input.task_subject {
        extra.insert(
            "task_subject".into(),
            serde_json::Value::String(subject.clone()),
        );
    }

    if !extra.is_empty() {
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::passthrough()
}
