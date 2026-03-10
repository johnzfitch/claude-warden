/// Check if output appears to be binary data
pub fn is_binary(text: &str) -> bool {
    let sample = &text[..text.len().min(512)];
    let null_count = sample.bytes().filter(|&b| b == 0).count();
    let non_printable = sample
        .bytes()
        .filter(|&b| b < 0x20 && b != b'\n' && b != b'\r' && b != b'\t')
        .count();
    null_count > 0 || non_printable > sample.len() / 4
}

/// Truncate text keeping the first and last portions, with a marker in the middle.
pub fn head_tail(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }

    let lines: Vec<&str> = text.lines().collect();
    let total_lines = lines.len();

    if total_lines <= 10 {
        // Too few lines to split meaningfully — just take first max_bytes chars
        let truncated: String = text.chars().take(max_bytes).collect();
        return format!(
            "{}\n\n[... truncated {} -> {} bytes, {} lines total]",
            truncated,
            text.len(),
            truncated.len(),
            total_lines
        );
    }

    // Take ~60% from head, ~30% from tail
    let head_lines = (total_lines * 6) / 10;
    let tail_lines = (total_lines * 3) / 10;
    let omitted = total_lines - head_lines - tail_lines;

    let head: String = lines[..head_lines].join("\n");
    let tail: String = lines[total_lines - tail_lines..].join("\n");

    // Check if still too large
    let combined_len = head.len() + tail.len() + 100;
    if combined_len > max_bytes {
        // Fall back to byte-based truncation
        let head_bytes = max_bytes * 6 / 10;
        let tail_bytes = max_bytes * 3 / 10;
        let head_part: String = text.chars().take(head_bytes).collect();
        let tail_part: String = text
            .chars()
            .rev()
            .take(tail_bytes)
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        return format!(
            "{}\n\n[... {} lines omitted ({} bytes total) ...]\n\n{}",
            head_part, omitted, text.len(), tail_part
        );
    }

    format!(
        "{}\n\n[... {} lines omitted ({} bytes total) ...]\n\n{}",
        head,
        omitted,
        text.len(),
        tail
    )
}

/// Estimate token count from byte length (rough: 1 token ≈ 3.5 bytes for English)
pub fn estimate_tokens(bytes: usize) -> i64 {
    (bytes as f64 / 3.5).ceil() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_binary() {
        assert!(!is_binary("hello world\n"));
        assert!(is_binary("\x00\x01\x02\x03\x04"));
    }

    #[test]
    fn test_head_tail_small() {
        let text = "line1\nline2\nline3";
        assert_eq!(head_tail(text, 1000), text);
    }

    #[test]
    fn test_head_tail_large() {
        let lines: Vec<String> = (0..100).map(|i| format!("line {}", i)).collect();
        let text = lines.join("\n");
        let result = head_tail(&text, 500);
        assert!(result.contains("omitted"));
        assert!(result.len() <= 700); // Some overhead from the marker
    }

    #[test]
    fn test_estimate_tokens() {
        assert_eq!(estimate_tokens(350), 100);
        assert_eq!(estimate_tokens(0), 0);
    }
}
