use std::sync::Arc;

use crate::observability::events;
use crate::security::bash_validator::ValidatorVerdict;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let tool = input.tool();
    let session_id = input.session();
    let is_subagent = input.is_subagent();

    // Record tool start timing
    if let Some(ref tool_use_id) = input.tool_use_id {
        let cmd = input.command();
        let _ = state
            .db
            .record_tool_start(tool_use_id, tool, session_id, &cmd);
    }

    // Increment session tool count
    let _ = state.db.increment_tool_count(session_id);

    match tool {
        "Bash" => handle_bash(state, input, is_subagent),
        "Write" => handle_write(state, input),
        "Edit" => handle_edit(state, input),
        "Read" => handle_read(state, input),
        "Glob" => handle_glob(state, input),
        "WebFetch" | "WebSearch" => handle_web(state, input),
        "NotebookEdit" => handle_notebook(state, input),
        _ => {
            // MCP tools and others — allow by default
            let event = events::make_event("allowed", tool, Some(session_id));
            events::emit_event(&state.db, &state.events_path, &event);
            HookOutput::suppress()
        }
    }
}

fn handle_bash(state: &Arc<AppState>, input: &HookInput, is_subagent: bool) -> HookOutput {
    let command = input.command();
    let session_id = input.session();

    if command.is_empty() {
        return HookOutput::suppress();
    }

    // Run through the tree-sitter validator
    let verdict = state
        .validator
        .validate(&command, &state.config.policy, is_subagent);

    match verdict {
        ValidatorVerdict::Allow => {
            let mut event = events::make_event("allowed", "Bash", Some(session_id));
            event.original_cmd = Some(truncate_cmd(&command));
            events::emit_event(&state.db, &state.events_path, &event);
            HookOutput::suppress()
        }
        ValidatorVerdict::Block { rule, reason } => {
            let mut event = events::make_event("blocked", "Bash", Some(session_id));
            event.rule = Some(rule.clone());
            event.original_cmd = Some(truncate_cmd(&command));
            events::emit_event(&state.db, &state.events_path, &event);
            HookOutput::deny(&reason)
        }
        ValidatorVerdict::Override { rule, new_command } => {
            // Record the quiet override for the post-tool-use handler
            if let Some(ref tool_use_id) = input.tool_use_id {
                let _ = state.db.insert_quiet_override(tool_use_id, &rule);
            }

            let mut event = events::make_event("allowed", "Bash", Some(session_id));
            event.rule = Some(format!("quiet_override:{}", rule));
            event.original_cmd = Some(truncate_cmd(&command));
            events::emit_event(&state.db, &state.events_path, &event);

            HookOutput::updated_input_with_allow(&new_command)
        }
    }
}

fn handle_write(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let _file_path = input.input_file_path();
    let session_id = input.session();

    // Check file size guard
    if let Some(ref content) = input.tool_input {
        if let Some(content_str) = content.get("content").and_then(|c| c.as_str()) {
            if content_str.len() > state.config.thresholds.write_max_bytes {
                let mut event = events::make_event("blocked", "Write", Some(session_id));
                event.rule = Some("write_too_large".to_string());
                events::emit_event(&state.db, &state.events_path, &event);
                return HookOutput::deny(&format!(
                    "Write content ({} bytes) exceeds limit ({} bytes)",
                    content_str.len(),
                    state.config.thresholds.write_max_bytes
                ));
            }
        }
    }

    let event = events::make_event("allowed", "Write", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

fn handle_edit(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();

    if let Some(ref ti) = input.tool_input {
        if let Some(new_str) = ti.get("new_string").and_then(|s| s.as_str()) {
            if new_str.len() > state.config.thresholds.edit_max_bytes {
                let mut event = events::make_event("blocked", "Edit", Some(session_id));
                event.rule = Some("edit_too_large".to_string());
                events::emit_event(&state.db, &state.events_path, &event);
                return HookOutput::deny(&format!(
                    "Edit new_string ({} bytes) exceeds limit ({} bytes)",
                    new_str.len(),
                    state.config.thresholds.edit_max_bytes
                ));
            }
        }
    }

    let event = events::make_event("allowed", "Edit", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

fn handle_read(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let file_path = input.input_file_path();
    let session_id = input.session();

    // Read guard: check file size before allowing
    if !file_path.is_empty() {
        if let Ok(metadata) = std::fs::metadata(&file_path) {
            let size_mb = metadata.len() as usize / (1024 * 1024);
            if size_mb > state.config.thresholds.read_guard_max_mb {
                let mut event = events::make_event("blocked", "Read", Some(session_id));
                event.rule = Some("read_guard".to_string());
                events::emit_event(&state.db, &state.events_path, &event);
                return HookOutput::deny(&format!(
                    "File {} is {}MB, exceeds {}MB limit. Use head -n 100 instead.",
                    file_path, size_mb, state.config.thresholds.read_guard_max_mb
                ));
            }
        }
    }

    let event = events::make_event("allowed", "Read", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

fn handle_glob(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let event = events::make_event("allowed", "Glob", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

fn handle_web(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let tool = input.tool();

    // Check URL against network policy
    if let Some(ref ti) = input.tool_input {
        if let Some(url) = ti.get("url").and_then(|u| u.as_str()) {
            if let Some(reason) =
                crate::security::network::check_url(url, &state.config.policy.network)
            {
                let mut event = events::make_event("blocked", tool, Some(session_id));
                event.rule = Some("network_block".to_string());
                events::emit_event(&state.db, &state.events_path, &event);
                return HookOutput::deny(&reason);
            }
        }
    }

    let event = events::make_event("allowed", tool, Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

fn handle_notebook(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let session_id = input.session();
    let event = events::make_event("allowed", "NotebookEdit", Some(session_id));
    events::emit_event(&state.db, &state.events_path, &event);
    HookOutput::suppress()
}

/// Truncate command for event logging (avoid huge commands in events)
fn truncate_cmd(cmd: &str) -> String {
    if cmd.len() > 200 {
        format!("{}...", &cmd[..200])
    } else {
        cmd.to_string()
    }
}
