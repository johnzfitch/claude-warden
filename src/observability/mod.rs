pub mod events;
pub mod notify;

#[cfg(feature = "otel")]
pub mod otel;

use crate::server::AppState;
use std::sync::Arc;

/// Generate Prometheus text format metrics
pub fn prometheus_metrics(state: &Arc<AppState>) -> String {
    let budget = state.db.get_budget().unwrap_or_default();
    let active = state.db.count_all_active_subagents().unwrap_or(0);
    let request_count = state
        .request_count
        .load(std::sync::atomic::Ordering::Relaxed);

    format!(
        "# HELP claude_budget_total_tokens Total token budget limit\n\
         # TYPE claude_budget_total_tokens gauge\n\
         claude_budget_total_tokens {}\n\
         # HELP claude_budget_consumed_tokens Tokens consumed\n\
         # TYPE claude_budget_consumed_tokens gauge\n\
         claude_budget_consumed_tokens {}\n\
         # HELP claude_budget_remaining_tokens Tokens remaining\n\
         # TYPE claude_budget_remaining_tokens gauge\n\
         claude_budget_remaining_tokens {}\n\
         # HELP claude_budget_active_subagents Active subagents\n\
         # TYPE claude_budget_active_subagents gauge\n\
         claude_budget_active_subagents {}\n\
         # HELP warden_hook_requests_total Total hook requests\n\
         # TYPE warden_hook_requests_total counter\n\
         warden_hook_requests_total {}\n",
        budget.total_limit,
        budget.consumed,
        budget.remaining,
        active,
        request_count,
    )
}
