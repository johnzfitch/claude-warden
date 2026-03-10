use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("stop", "", Some(session_id));
    if let Some(ref reason) = input.reason {
        let mut extra = serde_json::Map::new();
        extra.insert("reason".into(), serde_json::Value::String(reason.clone()));
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    // Passthrough — allow normal stop behavior
    HookOutput::passthrough()
}
