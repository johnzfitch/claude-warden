use std::sync::Arc;

use crate::server::AppState;
use crate::types::StatuslineInput;

/// Render the statusline from daemon state + Claude Code input.
/// Returns plain text (not JSON).
pub fn render(state: &Arc<AppState>, raw_input: &str) -> String {
    let input: StatuslineInput = match serde_json::from_str(raw_input) {
        Ok(v) => v,
        Err(_) => return "[Claude] parse error".to_string(),
    };

    let session_id = &input.session_id;
    let model = &input.model.display_name;
    let pct = input.context_window.used_percentage;
    let ctx_size = format_tokens(input.context_window.context_window_size);

    // Read state from SQLite
    let tool_count = state
        .db
        .get_session_tool_count(session_id)
        .unwrap_or(0);
    let tokens_saved = state.db.sum_tokens_saved(session_id).unwrap_or(0);
    let active_subs = state
        .db
        .count_active_subagents(session_id)
        .unwrap_or(0);
    let budget = state.db.get_budget().unwrap_or_default();
    let last_latency = state.db.last_tool_latency(session_id);

    // Build statusline
    let mut parts = Vec::new();

    // Model + context
    parts.push(format!("{} {:.0}%/{}", model, pct, ctx_size));

    // Tool count
    if tool_count > 0 {
        parts.push(format!("{}t", tool_count));
    }

    // Tokens saved
    if tokens_saved > 0 {
        parts.push(format!("-{}tok", format_number(tokens_saved)));
    }

    // Active subagents
    if active_subs > 0 {
        parts.push(format!("{}sub", active_subs));
    }

    // Budget
    if budget.consumed > 0 {
        parts.push(format!(
            "${:.2}/${:.2}",
            budget.consumed as f64 / 1000.0,
            budget.total_limit as f64 / 1000.0
        ));
    }

    // Last latency
    if let Some(lat) = last_latency {
        if lat > 1000 {
            parts.push(format!("{:.1}s", lat as f64 / 1000.0));
        } else {
            parts.push(format!("{}ms", lat));
        }
    }

    parts.join(" | ")
}

fn format_tokens(tokens: i64) -> String {
    if tokens >= 1_000_000 {
        format!("{:.1}M", tokens as f64 / 1_000_000.0)
    } else if tokens >= 1_000 {
        format!("{}K", tokens / 1_000)
    } else {
        tokens.to_string()
    }
}

fn format_number(n: i64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}
