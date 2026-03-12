use crate::config::Config;
use crate::types::HookInput;

/// Compress MCP tool output by stripping noise fields and optionally offloading to file.
/// Returns (compressed_output, additional_context) if compression applied.
pub fn compress(
    config: &Config,
    input: &HookInput,
    output: &str,
) -> Option<(String, String)> {
    let threshold = config.thresholds.mcp_threshold_bytes;
    if output.len() <= threshold {
        return None;
    }

    // Try JSON cleanup first
    if let Some(cleaned) = strip_mcp_noise(output) {
        if cleaned.len() <= threshold {
            return Some((cleaned, String::new()));
        }

        // Still too large — offload to file
        if let Some((summary, guidance)) = offload_to_file(input, &cleaned) {
            return Some((summary, guidance));
        }

        // Fallback: just truncate
        let truncated = super::truncate::head_tail(&cleaned, threshold);
        return Some((truncated, String::new()));
    }

    // Not JSON — just truncate
    let truncated = super::truncate::head_tail(output, threshold);
    Some((truncated, String::new()))
}

/// Strip noise fields from MCP JSON output
fn strip_mcp_noise(output: &str) -> Option<String> {
    let mut value: serde_json::Value = serde_json::from_str(output).ok()?;

    strip_fields_recursive(&mut value, &[
        "chunk_id",
        "score",
        "truncated_ids",
        "embeddings",
        "embedding",
    ]);

    Some(serde_json::to_string_pretty(&value).unwrap_or_else(|_| output.to_string()))
}

fn strip_fields_recursive(value: &mut serde_json::Value, fields: &[&str]) {
    match value {
        serde_json::Value::Object(map) => {
            for field in fields {
                map.remove(*field);
            }
            // Strip long hex hashes (>32 chars)
            let keys_to_check: Vec<String> = map.keys().cloned().collect();
            for key in keys_to_check {
                if let Some(serde_json::Value::String(s)) = map.get(&key) {
                    if s.len() > 32 && s.chars().all(|c| c.is_ascii_hexdigit()) {
                        map.insert(
                            key,
                            serde_json::Value::String(format!("{}...", &s[..8])),
                        );
                    }
                }
            }
            for (_, v) in map.iter_mut() {
                strip_fields_recursive(v, fields);
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr.iter_mut() {
                strip_fields_recursive(v, fields);
            }
        }
        _ => {}
    }
}

fn offload_to_file(
    input: &HookInput,
    content: &str,
) -> Option<(String, String)> {
    let offload_dir = std::env::temp_dir().join("claude-mcp-output");
    std::fs::create_dir_all(&offload_dir).ok()?;

    let session_short = input
        .session()
        .chars()
        .take(8)
        .collect::<String>();
    let tool = input.tool();
    let timestamp = chrono::Utc::now().timestamp();

    let filename = format!("{}-{}-{}.json", session_short, tool, timestamp);
    let filepath = offload_dir.join(&filename);

    std::fs::write(&filepath, content).ok()?;

    let line_count = content.lines().count();
    let summary = format!(
        "[MCP output offloaded: {} bytes, {} lines -> {}]",
        content.len(),
        line_count,
        filepath.display()
    );

    let guidance = format!(
        "Large MCP output saved to {}. Use `head -n 50 {}` to inspect.",
        filepath.display(),
        filepath.display()
    );

    Some((summary, guidance))
}
