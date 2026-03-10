use std::sync::Arc;

use crate::observability::{events, notify};
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    // Forward desktop notification
    let title = input.title.as_deref().unwrap_or("Claude Code");
    let message = input.message.as_deref().unwrap_or("");

    if !message.is_empty() {
        notify::send_notification(title, message);
    }

    let event = events::make_event("notification", "", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}
