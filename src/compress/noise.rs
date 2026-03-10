/// Strip noise patterns from tool output.
/// This includes system reminders, SSH connection messages, git hints, etc.
pub fn strip_noise(text: &str) -> String {
    let mut lines: Vec<&str> = Vec::new();
    let mut skip_until_end_tag = false;

    for line in text.lines() {
        // Skip system-reminder blocks
        if line.contains("<system-reminder>") {
            skip_until_end_tag = true;
            continue;
        }
        if line.contains("</system-reminder>") {
            skip_until_end_tag = false;
            continue;
        }
        if skip_until_end_tag {
            continue;
        }

        // Skip SSH connection noise
        if line.starts_with("Warning: Permanently added")
            || line.starts_with("Connection to ")
            || line.starts_with("debug1:")
        {
            continue;
        }

        // Skip git hints
        if line.starts_with("hint: ") {
            continue;
        }

        // Skip npm fund/audit notices
        if line.contains("npm fund") || line.starts_with("found 0 vulnerabilities") {
            continue;
        }

        lines.push(line);
    }

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_system_reminders() {
        let input = "line1\n<system-reminder>\nsome reminder\n</system-reminder>\nline2";
        let result = strip_noise(input);
        assert_eq!(result, "line1\nline2");
    }

    #[test]
    fn test_strip_ssh_noise() {
        let input = "output\nWarning: Permanently added 'host' to known hosts\nmore output";
        let result = strip_noise(input);
        assert_eq!(result, "output\nmore output");
    }

    #[test]
    fn test_strip_git_hints() {
        let input = "On branch main\nhint: use --force to override\nnothing to commit";
        let result = strip_noise(input);
        assert_eq!(result, "On branch main\nnothing to commit");
    }
}
