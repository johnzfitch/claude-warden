/// Send a desktop notification (placeholder — feature-gated behind notifications)
pub fn send_notification(title: &str, body: &str) {
    tracing::debug!("Notification: {} - {}", title, body);
    // With the `notifications` feature, this would use notify-rust
    // For now, try osascript on macOS or notify-send on Linux
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("osascript")
            .args([
                "-e",
                &format!(
                    "display notification \"{}\" with title \"{}\"",
                    body.replace('"', "\\\""),
                    title.replace('"', "\\\"")
                ),
            ])
            .spawn();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("notify-send")
            .args([title, body])
            .spawn();
    }
}
