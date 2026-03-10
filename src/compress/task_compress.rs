use crate::config::Config;

/// Compress Agent/task output by extracting structured results.
pub fn compress(config: &Config, output: &str) -> Option<String> {
    let threshold = config.thresholds.truncate_bytes;
    if output.len() <= threshold {
        return None;
    }

    // Simple head+tail truncation for now
    Some(super::truncate::head_tail(output, threshold))
}
