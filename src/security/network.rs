use crate::config::NetworkPolicy;

/// Check if a URL or host targets a blocked network address
pub fn check_url(url: &str, policy: &NetworkPolicy) -> Option<String> {
    // Check metadata service IPs
    for meta in &policy.block_metadata {
        if url.contains(meta.as_str()) {
            return Some(format!(
                "Access to metadata service '{}' is blocked",
                meta
            ));
        }
    }

    // Check private IP ranges
    if policy.block_private {
        if let Some(host) = extract_host(url) {
            if is_private_ip(&host) {
                return Some(format!("Access to private IP '{}' is blocked", host));
            }
        }
    }

    None
}

/// Check if a curl/wget command uploads data
pub fn check_data_upload(command: &str, policy: &NetworkPolicy) -> Option<String> {
    if !policy.block_data_upload {
        return None;
    }

    let upload_flags = [
        "-d ", "--data ", "--data-binary ", "--data-raw ", "--data-urlencode ",
        "-F ", "--form ", "--upload-file ", "-T ",
        "--post-data=", "--post-file=",
    ];

    let file_upload_patterns = [
        "-d @", "--data @", "--data-binary @", "-F \"file=@", "-F 'file=@",
    ];

    for pattern in &file_upload_patterns {
        if command.contains(pattern) {
            return Some("File upload via curl/wget is blocked".to_string());
        }
    }

    // Check for explicit uploads to external hosts
    for flag in &upload_flags {
        if command.contains(flag) {
            // Allow uploads to localhost
            if command.contains("localhost") || command.contains("127.0.0.1") {
                continue;
            }
            // This is a heuristic - full validation would need URL parsing
            return Some("Data upload to external host is blocked".to_string());
        }
    }

    None
}

fn extract_host(url: &str) -> Option<String> {
    let without_scheme = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .unwrap_or(url);
    let host_port = without_scheme.split('/').next()?;
    let host = host_port.split(':').next()?;
    Some(host.to_string())
}

fn is_private_ip(host: &str) -> bool {
    // Parse as IP and check private ranges
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        return ip.is_private()
            || ip.is_loopback()
            || ip.is_link_local()
            || ip.octets()[0] == 10
            || (ip.octets()[0] == 172 && (16..=31).contains(&ip.octets()[1]))
            || (ip.octets()[0] == 192 && ip.octets()[1] == 168);
    }
    false
}
