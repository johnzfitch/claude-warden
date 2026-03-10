use std::sync::Arc;

use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let tool = input.tool();
    let session_id = input.session();

    // Log permission request
    let event = events::make_event("permission_request", tool, Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);

    // Passthrough — let Claude Code handle the permission prompt
    HookOutput::passthrough()
}
