use std::sync::Arc;

use crate::compress;
use crate::compress::truncate;
use crate::observability::events;
use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let tool = input.tool();
    let session_id = input.session();

    // Record tool end timing
    if let Some(ref tool_use_id) = input.tool_use_id {
        if let Ok(Some(duration_ms)) = state.db.record_tool_end(tool_use_id) {
            let mut event = events::make_event("tool_latency", tool, Some(session_id));
            event.duration_ms = Some(duration_ms);
            event.original_cmd = Some(truncate_cmd(&input.command()));
            events::emit_event(&state.db, &state.events_path, &event);
        }
    }

    // Get tool output
    let output_text = input.tool_output_text();
    if output_text.is_empty() {
        return HookOutput::suppress();
    }

    let original_bytes = output_text.len() as i64;
    let original_lines = output_text.lines().count() as i64;

    // Emit output size event
    let mut size_event = events::make_event("tool_output_size", tool, Some(session_id));
    size_event.output_bytes = Some(original_bytes);
    size_event.output_lines = Some(original_lines);
    size_event.estimated_tokens = Some(truncate::estimate_tokens(original_bytes as usize));
    size_event.original_cmd = Some(truncate_cmd(&input.command()));
    events::emit_event(&state.db, &state.events_path, &size_event);

    // Run compression pipeline
    let (final_text, rule) = compress::process(&state.config, input, &output_text);

    let final_bytes = final_text.len() as i64;
    let tokens_saved = truncate::estimate_tokens((original_bytes - final_bytes).max(0) as usize);

    // Track subagent bytes (atomic — no preliminary/correction split)
    if input.is_subagent() {
        if let Some(agent_id) = input.agent_id_from_path() {
            let _ = state.db.add_subagent_bytes(&agent_id, final_bytes);
        }
    }

    // Check for quiet override reminder from pre-tool-use
    let mut additional_context = None;
    if let Some(ref tool_use_id) = input.tool_use_id {
        if let Ok(Some(override_rule)) = state.db.take_quiet_override(tool_use_id) {
            additional_context = Some(format_quiet_reminder(&override_rule, input));
        }
    }

    if let Some(ref rule_name) = rule {
        // Emit truncation/compression event
        let mut event = events::make_event("truncated", tool, Some(session_id));
        event.rule = Some(rule_name.clone());
        event.original_output_bytes = Some(original_bytes);
        event.final_output_bytes = Some(final_bytes);
        event.tokens_saved = Some(tokens_saved);
        event.original_cmd = Some(truncate_cmd(&input.command()));
        events::emit_event(&state.db, &state.events_path, &event);

        // If we have both modified output and additional context, combine them
        if let Some(ctx) = additional_context {
            // Return modified output with context as stderr
            let mut output = HookOutput::modify(final_text);
            output.hook_specific_output = Some(serde_json::json!({
                "hookEventName": "PostToolUse",
                "additionalContext": ctx
            }));
            return output;
        }

        return HookOutput::modify(final_text);
    }

    // No compression needed, but maybe we have a quiet override reminder
    if let Some(ctx) = additional_context {
        return HookOutput::additional_context("PostToolUse", &ctx);
    }

    HookOutput::suppress()
}

pub fn handle_failure(state: &Arc<AppState>, input: &HookInput) -> HookOutput {
    let tool = input.tool();
    let session_id = input.session();

    // Record tool end timing even for failures
    if let Some(ref tool_use_id) = input.tool_use_id {
        let _ = state.db.record_tool_end(tool_use_id);
    }

    // Log the error event
    let mut event = events::make_event("tool_error", tool, Some(session_id));
    if let Some(ref error) = input.error {
        let mut extra = serde_json::Map::new();
        extra.insert("error".into(), serde_json::Value::String(error.clone()));
        if let Some(ref et) = input.error_type {
            extra.insert("error_type".into(), serde_json::Value::String(et.clone()));
        }
        event.extra = Some(extra);
    }
    events::emit_event(&state.db, &state.events_path, &event);

    HookOutput::suppress()
}

fn format_quiet_reminder(rule: &str, input: &HookInput) -> String {
    let _tool = input.tool();
    let cmd = input.command();

    match rule {
        "git_commit" | "git_clone" | "git_fetch" | "git_pull" => {
            format!(
                "IMPORTANT: The warden added -q to your {} command to reduce output. \
                 Always include -q or --quiet when running git commands.",
                cmd.split_whitespace().take(2).collect::<Vec<_>>().join(" ")
            )
        }
        "npm_install" => {
            "IMPORTANT: The warden added --silent to npm install to reduce output. \
             Always include --silent when running npm install/ci."
                .to_string()
        }
        "cargo_build" => {
            "IMPORTANT: The warden added -q to cargo build to reduce output. \
             Always include -q when running cargo build."
                .to_string()
        }
        _ => {
            format!(
                "IMPORTANT: The warden modified your command to reduce output (rule: {}). \
                 Include the quiet flag next time.",
                rule
            )
        }
    }
}

fn truncate_cmd(cmd: &str) -> String {
    if cmd.len() > 200 {
        format!("{}...", &cmd[..200])
    } else {
        cmd.to_string()
    }
}
