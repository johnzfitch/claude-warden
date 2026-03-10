use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    let mut event = events::make_event("config_change", "", Some(session_id));
    if let Some(ref fp) = input.file_path {
        let mut extra = serde_json::Map::new();
        extra.insert(
            "file_path".into(),
            serde_json::Value::String(fp.clone()),
        );
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}
