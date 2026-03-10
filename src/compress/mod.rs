pub mod mcp_compress;
pub mod noise;
pub mod read_compress;
pub mod task_compress;
pub mod truncate;

use crate::config::Config;
use crate::types::HookInput;

/// Process tool output through the compression pipeline.
/// Returns (final_text, rule_applied) — None rule means no compression.
pub fn process(
    config: &Config,
    input: &HookInput,
    output: &str,
) -> (String, Option<String>) {
    let tool = input.tool();
    let output_len = output.len();

    // Binary detection — suppress entirely
    if truncate::is_binary(output) {
        return (
            "[Binary output suppressed]".to_string(),
            Some("binary_suppress".to_string()),
        );
    }

    // Noise stripping (system reminders, SSH noise, git hints)
    let cleaned = noise::strip_noise(output);

    // Tool-specific compression
    match tool {
        "Read" => {
            if let Some(compressed) = read_compress::compress(config, input, &cleaned) {
                return (compressed, Some("read_compress".to_string()));
            }
        }
        "Agent" => {
            if let Some(compressed) = task_compress::compress(config, &cleaned) {
                return (compressed, Some("task_compress".to_string()));
            }
        }
        _ => {
            // Check if it's an MCP tool
            if tool.starts_with("mcp__") || tool.contains("mcp") {
                if let Some((compressed, _ctx)) =
                    mcp_compress::compress(config, input, &cleaned)
                {
                    return (compressed, Some("mcp_compress".to_string()));
                }
            }
        }
    }

    // Generic truncation for large outputs
    let threshold = if input.is_subagent() {
        config.thresholds.subagent_read_bytes
    } else {
        config.thresholds.truncate_bytes
    };

    if cleaned.len() > threshold {
        let truncated = truncate::head_tail(&cleaned, threshold);
        return (truncated, Some("truncated".to_string()));
    }

    // Suppress very large outputs entirely
    if output_len > config.thresholds.suppress_bytes {
        return (
            format!(
                "[Output suppressed: {} bytes exceeds {} byte limit]",
                output_len, config.thresholds.suppress_bytes
            ),
            Some("suppressed".to_string()),
        );
    }

    (cleaned, None)
}
