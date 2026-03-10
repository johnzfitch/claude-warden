use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let event_name = input.hook_event_name.as_str();

    let mut event = events::make_event(event_name, "", Some(session_id));
    let mut extra = serde_json::Map::new();

    if let Some(ref id) = input.elicitation_id {
        extra.insert(
            "elicitation_id".into(),
            serde_json::Value::String(id.clone()),
        );
    }
    if let Some(ref server) = input.mcp_server_name {
        extra.insert(
            "mcp_server_name".into(),
            serde_json::Value::String(server.clone()),
        );
    }

    if !extra.is_empty() {
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    // Passthrough — let Claude Code handle elicitation
    HookOutput::passthrough()
}
