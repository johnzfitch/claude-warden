use serde::{Deserialize, Serialize};
use serde_json::Value;

/// All fields from every hook event type.
/// Optional fields are None when the event doesn't include them.
#[derive(Deserialize, Debug, Default)]
pub struct HookInput {
    pub hook_event_name: String,
    pub session_id: Option<String>,
    pub transcript_path: Option<String>,
    pub cwd: Option<String>,
    pub permission_mode: Option<String>,

    // Tool events
    pub tool_name: Option<String>,
    pub tool_input: Option<Value>,
    pub tool_response: Option<Value>,
    pub tool_use_id: Option<String>,

    // Error events
    pub error: Option<String>,
    pub error_type: Option<String>,
    pub is_interrupt: Option<bool>,
    pub is_timeout: Option<bool>,

    // Session events
    pub source: Option<String>,
    pub reason: Option<String>,
    pub trigger: Option<String>,

    // Subagent events
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub agent_transcript_path: Option<String>,
    pub worktree_path: Option<String>,

    // Team events
    pub teammate_name: Option<String>,
    pub team_name: Option<String>,
    pub task_id: Option<String>,
    pub task_subject: Option<String>,
    pub task_description: Option<String>,

    // User prompt
    pub prompt: Option<String>,

    // Config
    pub file_path: Option<String>,

    // Notification
    pub message: Option<String>,
    pub title: Option<String>,
    pub notification_type: Option<String>,

    // Worktree
    pub name: Option<String>,

    // Elicitation
    pub mcp_server_name: Option<String>,
    pub mode: Option<String>,
    pub url: Option<String>,
    pub elicitation_id: Option<String>,
    pub requested_schema: Option<Value>,
    pub action: Option<String>,
    pub content: Option<Value>,

    // InstructionsLoaded
    pub memory_type: Option<String>,
    pub load_reason: Option<String>,
    pub globs: Option<Vec<String>>,
    pub trigger_file_path: Option<String>,
    pub parent_file_path: Option<String>,

    // Stop hook guard
    pub stop_hook_active: Option<bool>,
    pub last_assistant_message: Option<String>,
}

impl HookInput {
    /// Extract command from tool_input.command
    pub fn command(&self) -> String {
        self.tool_input
            .as_ref()
            .and_then(|v| v.get("command"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// Extract file_path from tool_input.file_path
    pub fn input_file_path(&self) -> String {
        self.tool_input
            .as_ref()
            .and_then(|v| v.get("file_path"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// Extract tool output text from tool_response
    pub fn tool_output_text(&self) -> String {
        self.tool_response
            .as_ref()
            .and_then(|v| {
                // Standard: .content[0].text
                v.get("content")
                    .and_then(|c| c.get(0))
                    .and_then(|c| c.get("text"))
                    .and_then(|t| t.as_str())
                    // MCP: tool_response is array [{type, text}]
                    .or_else(|| {
                        v.get(0)
                            .and_then(|c| c.get("text"))
                            .and_then(|t| t.as_str())
                    })
            })
            .unwrap_or("")
            .to_string()
    }

    /// Is this from a subagent?
    pub fn is_subagent(&self) -> bool {
        self.transcript_path
            .as_deref()
            .map(|p| p.contains("/subagents/") || p.contains("/tmp/"))
            .unwrap_or(false)
    }

    /// Extract agent ID from transcript path
    pub fn agent_id_from_path(&self) -> Option<String> {
        let path = self.transcript_path.as_deref()?;
        if !path.contains("/subagents/") {
            return None;
        }
        let filename = path.rsplit('/').next()?;
        let stem = filename.strip_suffix(".jsonl").unwrap_or(filename);
        let id = stem.strip_prefix("agent-").unwrap_or(stem);
        if id
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            Some(id.to_string())
        } else {
            None
        }
    }

    /// Get the tool name or empty string
    pub fn tool(&self) -> &str {
        self.tool_name.as_deref().unwrap_or("")
    }

    /// Get the session ID or empty string
    pub fn session(&self) -> &str {
        self.session_id.as_deref().unwrap_or("")
    }
}

/// Output from a handler. Translated to HTTP JSON response.
#[derive(Debug, Default)]
pub struct HookOutput {
    pub suppress_output: Option<bool>,
    pub modify_output: Option<String>,
    pub hook_specific_output: Option<Value>,
    pub stderr_message: Option<String>,
}

impl HookOutput {
    /// Allow the tool call, suppress hook output
    pub fn suppress() -> Self {
        Self {
            suppress_output: Some(true),
            ..Default::default()
        }
    }

    /// Passthrough — no modifications
    pub fn passthrough() -> Self {
        Self::default()
    }

    /// Block the tool call with a reason
    pub fn deny(reason: &str) -> Self {
        Self {
            hook_specific_output: Some(serde_json::json!({
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason
            })),
            stderr_message: Some(format!("warden: {}", reason)),
            ..Default::default()
        }
    }

    /// Modify the tool output text
    pub fn modify(text: String) -> Self {
        Self {
            modify_output: Some(text),
            ..Default::default()
        }
    }

    /// Allow with updated input (e.g., adding quiet flags)
    pub fn updated_input_with_allow(command: &str) -> Self {
        Self {
            hook_specific_output: Some(serde_json::json!({
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": { "command": command }
            })),
            ..Default::default()
        }
    }

    /// Add context to the conversation
    pub fn additional_context(event_name: &str, context: &str) -> Self {
        Self {
            hook_specific_output: Some(serde_json::json!({
                "hookEventName": event_name,
                "additionalContext": context
            })),
            ..Default::default()
        }
    }

    /// Deny a permission request
    pub fn permission_deny(message: &str) -> Self {
        Self {
            hook_specific_output: Some(serde_json::json!({
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": message
                }
            })),
            ..Default::default()
        }
    }

    /// Allow a permission request
    pub fn permission_allow() -> Self {
        Self {
            hook_specific_output: Some(serde_json::json!({
                "hookEventName": "PermissionRequest",
                "decision": { "behavior": "allow" }
            })),
            ..Default::default()
        }
    }

    /// Convert to the JSON format Claude Code expects from HTTP hooks.
    pub fn to_http_response(&self) -> Value {
        let mut obj = serde_json::Map::new();

        if let Some(true) = self.suppress_output {
            obj.insert("suppressOutput".into(), Value::Bool(true));
        }
        if let Some(ref text) = self.modify_output {
            obj.insert("modifyOutput".into(), Value::String(text.clone()));
        }
        if let Some(ref hso) = self.hook_specific_output {
            obj.insert("hookSpecificOutput".into(), hso.clone());
        }

        Value::Object(obj)
    }
}

/// Event emitted to JSONL and SQLite
#[derive(Debug, Serialize, Clone)]
pub struct Event {
    pub timestamp: f64,
    pub event_type: String,
    pub tool: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_cmd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens_saved: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_output_bytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub final_output_bytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_bytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_lines: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(flatten)]
    pub extra: Option<serde_json::Map<String, Value>>,
}

impl Event {
    pub fn new(event_type: &str, tool: &str) -> Self {
        Self {
            timestamp: 0.0,
            event_type: event_type.to_string(),
            tool: tool.to_string(),
            session_id: None,
            original_cmd: None,
            tokens_saved: None,
            original_output_bytes: None,
            final_output_bytes: None,
            rule: None,
            output_bytes: None,
            output_lines: None,
            estimated_tokens: None,
            duration_ms: None,
            extra: None,
        }
    }
}

/// Statusline input from Claude Code
#[derive(Deserialize, Debug)]
pub struct StatuslineInput {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub model: StatuslineModel,
    #[serde(default)]
    pub context_window: StatuslineContextWindow,
}

#[derive(Deserialize, Debug, Default)]
pub struct StatuslineModel {
    #[serde(default)]
    pub display_name: String,
}

#[derive(Deserialize, Debug, Default)]
pub struct StatuslineContextWindow {
    #[serde(default)]
    pub used_percentage: f64,
    #[serde(default)]
    pub context_window_size: i64,
}

/// Budget info returned by /budget
#[derive(Serialize, Debug, Default)]
pub struct BudgetInfo {
    pub consumed: i64,
    pub total_limit: i64,
    pub remaining: i64,
    pub percentage_used: f64,
}
