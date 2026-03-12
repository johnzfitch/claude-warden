use crate::config::Config;
use crate::types::HookInput;

/// Compress Read tool output by extracting structural information.
pub fn compress(config: &Config, input: &HookInput, output: &str) -> Option<String> {
    let file_path = input.input_file_path();
    let threshold = if input.is_subagent() {
        config.thresholds.subagent_read_bytes
    } else {
        config.thresholds.truncate_bytes
    };

    if output.len() <= threshold {
        return None;
    }

    let ext = file_path.rsplit('.').next().unwrap_or("");

    match ext {
        "json" | "yaml" | "yml" | "toml" => compress_config(output, threshold),
        "rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go" | "java" | "rb" | "cs" | "cpp"
        | "c" | "h" | "hpp" => compress_code(output, threshold),
        "log" | "txt" => {
            let lines: Vec<&str> = output.lines().collect();
            if lines.len() > 50 {
                let tail: String = lines[lines.len() - 50..].join("\n");
                Some(format!(
                    "[... {} lines total, showing last 50 ...]\n{}",
                    lines.len(),
                    tail
                ))
            } else {
                None
            }
        }
        _ => None,
    }
}

fn compress_config(output: &str, max_bytes: usize) -> Option<String> {
    if output.len() <= max_bytes {
        return None;
    }

    let lines: Vec<&str> = output.lines().collect();
    let mut result = Vec::new();
    let mut byte_count = 0;

    for line in &lines {
        if byte_count + line.len() + 1 > max_bytes {
            break;
        }
        result.push(line.to_string());
        byte_count += line.len() + 1;
    }

    result.push(format!(
        "\n[... truncated: {} lines / {} bytes total]",
        lines.len(),
        output.len()
    ));

    Some(result.join("\n"))
}

fn compress_code(output: &str, max_bytes: usize) -> Option<String> {
    if output.len() <= max_bytes {
        return None;
    }

    let lines: Vec<&str> = output.lines().collect();
    let mut result: Vec<String> = Vec::new();
    let mut byte_count = 0;

    for line in &lines {
        let trimmed = line.trim();

        // Always keep: imports, use statements, module declarations
        let is_structural = trimmed.starts_with("import ")
            || trimmed.starts_with("use ")
            || trimmed.starts_with("from ")
            || trimmed.starts_with("require(")
            || trimmed.starts_with("mod ")
            || trimmed.starts_with("package ")
            || trimmed.starts_with("#include")
            || trimmed.starts_with("fn ")
            || trimmed.starts_with("pub fn ")
            || trimmed.starts_with("pub(crate) fn ")
            || trimmed.starts_with("async fn ")
            || trimmed.starts_with("pub async fn ")
            || trimmed.starts_with("def ")
            || trimmed.starts_with("class ")
            || trimmed.starts_with("struct ")
            || trimmed.starts_with("enum ")
            || trimmed.starts_with("impl ")
            || trimmed.starts_with("trait ")
            || trimmed.starts_with("interface ")
            || trimmed.starts_with("type ")
            || trimmed.starts_with("function ")
            || trimmed.starts_with("export ")
            || trimmed.starts_with("const ")
            || trimmed.starts_with("pub const ")
            || trimmed.starts_with("static ")
            || trimmed.starts_with("pub static ");

        if is_structural || byte_count + line.len() + 1 <= max_bytes {
            if trimmed.is_empty() {
                if result.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
                    continue;
                }
                result.push(String::new());
                byte_count += 1;
            } else {
                result.push(line.to_string());
                byte_count += line.len() + 1;
            }
        }
    }

    if byte_count < output.len() {
        result.push(format!(
            "\n[... structural extract: {} / {} bytes, {} lines total]",
            byte_count,
            output.len(),
            lines.len()
        ));
    }

    Some(result.join("\n"))
}
