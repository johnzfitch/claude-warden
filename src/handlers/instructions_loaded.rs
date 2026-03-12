use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("instructions_loaded", "", Some(session_id));
    let mut extra = serde_json::Map::new();

    if let Some(ref mt) = input.memory_type {
        extra.insert(
            "memory_type".into(),
            serde_json::Value::String(mt.clone()),
        );
    }
    if let Some(ref lr) = input.load_reason {
        extra.insert(
            "load_reason".into(),
            serde_json::Value::String(lr.clone()),
        );
    }

    if !extra.is_empty() {
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}
