use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

/// Main daemon configuration loaded from warden.toml
#[derive(Debug, Clone)]
pub struct Config {
    pub thresholds: Thresholds,
    pub daemon: DaemonConfig,
    pub policy: Policy,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Thresholds {
    #[serde(default = "default_truncate_bytes")]
    pub truncate_bytes: usize,
    #[serde(default = "default_subagent_read_bytes")]
    pub subagent_read_bytes: usize,
    #[serde(default = "default_suppress_bytes")]
    pub suppress_bytes: usize,
    #[serde(default = "default_read_guard_max_mb")]
    pub read_guard_max_mb: usize,
    #[serde(default = "default_write_max_bytes")]
    pub write_max_bytes: usize,
    #[serde(default = "default_edit_max_bytes")]
    pub edit_max_bytes: usize,
    #[serde(default = "default_notebook_max_bytes")]
    pub notebook_max_bytes: usize,
    #[serde(default = "default_mcp_threshold_bytes")]
    pub mcp_threshold_bytes: usize,
    #[serde(default = "default_budget_total")]
    pub budget_total: i64,
    #[serde(default = "default_call_limit")]
    pub default_call_limit: i64,
    #[serde(default = "default_byte_limit")]
    pub default_byte_limit: i64,
    #[serde(default)]
    pub subagent_call_limits: HashMap<String, i64>,
    #[serde(default)]
    pub subagent_byte_limits: HashMap<String, i64>,
}

fn default_truncate_bytes() -> usize {
    20480
}
fn default_subagent_read_bytes() -> usize {
    10240
}
fn default_suppress_bytes() -> usize {
    524288
}
fn default_read_guard_max_mb() -> usize {
    2
}
fn default_write_max_bytes() -> usize {
    102400
}
fn default_edit_max_bytes() -> usize {
    51200
}
fn default_notebook_max_bytes() -> usize {
    51200
}
fn default_mcp_threshold_bytes() -> usize {
    10500
}
fn default_budget_total() -> i64 {
    280000
}
fn default_call_limit() -> i64 {
    30
}
fn default_byte_limit() -> i64 {
    102400
}

impl Default for Thresholds {
    fn default() -> Self {
        Self {
            truncate_bytes: default_truncate_bytes(),
            subagent_read_bytes: default_subagent_read_bytes(),
            suppress_bytes: default_suppress_bytes(),
            read_guard_max_mb: default_read_guard_max_mb(),
            write_max_bytes: default_write_max_bytes(),
            edit_max_bytes: default_edit_max_bytes(),
            notebook_max_bytes: default_notebook_max_bytes(),
            mcp_threshold_bytes: default_mcp_threshold_bytes(),
            budget_total: default_budget_total(),
            default_call_limit: default_call_limit(),
            default_byte_limit: default_byte_limit(),
            subagent_call_limits: HashMap::new(),
            subagent_byte_limits: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct DaemonConfig {
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_idle_timeout")]
    pub idle_timeout: u64,
}

fn default_port() -> u16 {
    7483
}
fn default_idle_timeout() -> u64 {
    300
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            port: default_port(),
            idle_timeout: default_idle_timeout(),
        }
    }
}

/// TOML file layout for warden.toml
#[derive(Debug, Deserialize)]
struct TomlConfig {
    #[serde(default)]
    thresholds: Thresholds,
    #[serde(default)]
    daemon: DaemonConfig,
}

/// Security policy loaded from policy.toml
#[derive(Debug, Clone)]
pub struct Policy {
    pub bash: BashPolicy,
    pub network: NetworkPolicy,
    pub subagent: SubagentPolicy,
    pub quiet_overrides: Vec<QuietOverrideRule>,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            bash: BashPolicy::default(),
            network: NetworkPolicy::default(),
            subagent: SubagentPolicy::default(),
            quiet_overrides: default_quiet_overrides(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct BashPolicy {
    pub allow_simple: Vec<String>,
    pub deny: Vec<String>,
    pub deny_patterns: Vec<DenyPattern>,
    pub block_interpreter_pipe: bool,
    pub interpreters: Vec<String>,
}

impl Default for BashPolicy {
    fn default() -> Self {
        Self {
            allow_simple: vec![
                "ls", "cat", "head", "tail", "wc", "stat", "file", "du", "md5sum", "sha256sum",
                "sha1sum", "cksum", "whoami", "hostname", "type", "man", "locale", "tree", "rg",
                "grep", "awk", "sed", "sort", "uniq", "cut", "git", "npm", "cargo", "make",
                "pip", "pip3", "docker", "kubectl", "curl", "wget", "ssh", "scp", "rsync",
                "echo", "printf", "test", "true", "false", "date", "id", "uname", "which",
                "dirname", "basename", "realpath", "readlink", "mkdir", "cp", "mv", "touch",
                "chmod", "chown", "ln", "diff", "patch", "tar", "gzip", "gunzip", "zip",
                "unzip", "find", "xargs", "tee", "tr", "rev", "fold", "fmt", "column",
                "yes", "seq", "shuf", "comm", "join", "paste", "expand", "unexpand",
                "python", "python3", "ruby", "node", "bun", "deno", "go", "rustc",
                "java", "javac", "dotnet", "gcc", "g++", "clang",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
            deny: vec![
                "mkfs", "dd", "nc", "ncat", "netcat", "socat", "nmap", "masscan", "zmap",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
            deny_patterns: vec![
                DenyPattern {
                    rule: "destructive_rm".to_string(),
                    command: "rm".to_string(),
                    args_contain: vec![
                        "-rf /".to_string(),
                        "-fr /".to_string(),
                        "-rf ~".to_string(),
                        "-fr ~".to_string(),
                        "-rf .".to_string(),
                        "-fr .".to_string(),
                    ],
                    bare: false,
                },
                DenyPattern {
                    rule: "env_dump".to_string(),
                    command: "env".to_string(),
                    args_contain: vec![],
                    bare: true,
                },
                DenyPattern {
                    rule: "env_dump".to_string(),
                    command: "printenv".to_string(),
                    args_contain: vec![],
                    bare: true,
                },
                DenyPattern {
                    rule: "env_dump".to_string(),
                    command: "export".to_string(),
                    args_contain: vec![],
                    bare: true,
                },
                DenyPattern {
                    rule: "proc_environ".to_string(),
                    command: "*".to_string(),
                    args_contain: vec![
                        "/proc/self/environ".to_string(),
                        "/proc/*/environ".to_string(),
                    ],
                    bare: false,
                },
            ],
            block_interpreter_pipe: true,
            interpreters: vec![
                "bash", "sh", "zsh", "python", "python3", "perl", "ruby", "node",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct DenyPattern {
    pub rule: String,
    pub command: String,
    pub args_contain: Vec<String>,
    pub bare: bool,
}

#[derive(Debug, Clone)]
pub struct NetworkPolicy {
    pub block_metadata: Vec<String>,
    pub block_private: bool,
    pub block_data_upload: bool,
}

impl Default for NetworkPolicy {
    fn default() -> Self {
        Self {
            block_metadata: vec![
                "169.254.169.254".to_string(),
                "metadata.google.internal".to_string(),
                "100.100.100.200".to_string(),
            ],
            block_private: true,
            block_data_upload: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SubagentPolicy {
    pub deny_commands: Vec<String>,
}

impl Default for SubagentPolicy {
    fn default() -> Self {
        Self {
            deny_commands: vec!["find", "grep", "ssh", "scp", "rsync"]
                .into_iter()
                .map(String::from)
                .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct QuietOverrideRule {
    pub name: String,
    pub match_commands: Vec<String>,
    pub flag: String,
    pub extra_flags: Vec<String>,
    pub not_present: Vec<String>,
}

fn default_quiet_overrides() -> Vec<QuietOverrideRule> {
    vec![
        QuietOverrideRule {
            name: "git_commit".into(),
            match_commands: vec!["git commit".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "git_clone".into(),
            match_commands: vec!["git clone".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "git_fetch".into(),
            match_commands: vec!["git fetch".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "git_pull".into(),
            match_commands: vec!["git pull".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "npm_install".into(),
            match_commands: vec!["npm install".into(), "npm i ".into(), "npm ci".into()],
            flag: "--silent".into(),
            extra_flags: vec![],
            not_present: vec!["--silent".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "cargo_build".into(),
            match_commands: vec!["cargo build".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "make".into(),
            match_commands: vec!["make".into()],
            flag: "-s".into(),
            extra_flags: vec![],
            not_present: vec!["-s".into(), "--silent".into()],
        },
        QuietOverrideRule {
            name: "pip_install".into(),
            match_commands: vec!["pip install".into(), "pip3 install".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
        QuietOverrideRule {
            name: "docker_build".into(),
            match_commands: vec!["docker build".into(), "docker pull".into()],
            flag: "-q".into(),
            extra_flags: vec![],
            not_present: vec!["-q".into(), "--quiet".into()],
        },
    ]
}

impl Config {
    pub fn load(config_path: &Path, policy_path: &Path) -> Result<Self> {
        let thresholds;
        let daemon;

        if config_path.exists() {
            let content = std::fs::read_to_string(config_path)?;
            let toml_config: TomlConfig = toml::from_str(&content)?;
            thresholds = toml_config.thresholds;
            daemon = toml_config.daemon;
        } else {
            tracing::info!("Config file not found at {:?}, using defaults", config_path);
            thresholds = Thresholds::default();
            daemon = DaemonConfig::default();
        }

        let policy = if policy_path.exists() {
            tracing::info!("Loading policy from {:?}", policy_path);
            // TODO: Parse TOML policy file into Policy struct
            // For now, use defaults
            Policy::default()
        } else {
            tracing::info!(
                "Policy file not found at {:?}, using defaults",
                policy_path
            );
            Policy::default()
        };

        Ok(Config {
            thresholds,
            daemon,
            policy,
        })
    }

    /// Get the call limit for a given agent type
    pub fn call_limit_for(&self, agent_type: &str) -> i64 {
        self.thresholds
            .subagent_call_limits
            .get(agent_type)
            .copied()
            .unwrap_or(self.thresholds.default_call_limit)
    }

    /// Get the byte limit for a given agent type
    pub fn byte_limit_for(&self, agent_type: &str) -> i64 {
        self.thresholds
            .subagent_byte_limits
            .get(agent_type)
            .copied()
            .unwrap_or(self.thresholds.default_byte_limit)
    }
}

impl Policy {
    /// Quick check for simple commands (no metacharacters)
    pub fn check_simple(
        &self,
        bin: &str,
        full_command: &str,
        is_subagent: bool,
    ) -> PolicyVerdict {
        // Check explicit deny list
        if self.bash.deny.iter().any(|d| d == bin) {
            return PolicyVerdict::Block {
                rule: "denied_command".to_string(),
                reason: format!("Command '{}' is not allowed", bin),
            };
        }

        // Check deny patterns
        for pattern in &self.bash.deny_patterns {
            if pattern.command == bin || pattern.command == "*" {
                if pattern.bare && full_command.trim() == bin {
                    return PolicyVerdict::Block {
                        rule: pattern.rule.clone(),
                        reason: format!("Bare '{}' is not allowed", bin),
                    };
                }
                for arg_pat in &pattern.args_contain {
                    if full_command.contains(arg_pat.as_str()) {
                        return PolicyVerdict::Block {
                            rule: pattern.rule.clone(),
                            reason: format!(
                                "Command contains blocked pattern '{}'",
                                arg_pat
                            ),
                        };
                    }
                }
            }
        }

        // Subagent restrictions
        if is_subagent && self.subagent.deny_commands.iter().any(|d| d == bin) {
            return PolicyVerdict::Block {
                rule: "subagent_denied".to_string(),
                reason: format!("Subagents cannot use '{}'", bin),
            };
        }

        // Check quiet overrides
        for qo in &self.quiet_overrides {
            if qo
                .match_commands
                .iter()
                .any(|mc| full_command.starts_with(mc.as_str()))
            {
                if !qo.not_present.iter().any(|np| full_command.contains(np.as_str())) {
                    let new_cmd = format!("{} {}", full_command, qo.flag);
                    return PolicyVerdict::Override {
                        rule: qo.name.clone(),
                        new_command: new_cmd,
                    };
                }
            }
        }

        PolicyVerdict::Allow
    }
}

#[derive(Debug)]
pub enum PolicyVerdict {
    Allow,
    Block { rule: String, reason: String },
    Override { rule: String, new_command: String },
}
