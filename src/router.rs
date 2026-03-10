use std::sync::Arc;

use crate::handlers;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn dispatch(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    match input.hook_event_name.as_str() {
        "PreToolUse" => handlers::pre_tool_use::handle(state, input),
        "PostToolUse" => handlers::post_tool_use::handle(state, input),
        "PostToolUseFailure" => handlers::post_tool_use::handle_failure(state, input),
        "PermissionRequest" => handlers::permission_request::handle(state, input),
        "UserPromptSubmit" => handlers::user_prompt::handle(state, input),
        "Stop" => handlers::stop::handle(state, input),
        "PreCompact" => handlers::pre_compact::handle(state, input),
        "SubagentStart" => handlers::subagent::handle_start(state, input),
        "SubagentStop" => handlers::subagent::handle_stop(state, input),
        "ConfigChange" => handlers::config_change::handle(state, input),
        "Notification" => handlers::notification::handle(state, input),
        "Elicitation" | "ElicitationResult" => handlers::elicitation::handle(state, input),
        "InstructionsLoaded" => handlers::instructions_loaded::handle(state, input),
        "TeammateIdle" => handlers::team::handle_idle(state, input),
        "TaskCompleted" => handlers::team::handle_completed(state, input),
        "WorktreeCreate" => handlers::worktree::handle_create(state, input),
        "WorktreeRemove" => handlers::worktree::handle_remove(state, input),
        _ => {
            tracing::debug!("Unknown hook event: {}", input.hook_event_name);
            HookOutput::suppress()
        }
    }
}
