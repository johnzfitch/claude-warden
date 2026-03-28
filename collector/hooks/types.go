package hooks

import "encoding/json"

type ToolResponseBlock struct {
	Type string `json:"type,omitempty"`
	Text string `json:"text,omitempty"`
}

type HookToolResponse struct {
	Content []ToolResponseBlock `json:"content,omitempty"`
}

func (r *HookToolResponse) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		return nil
	}

	var object struct {
		Content []ToolResponseBlock `json:"content"`
	}
	if err := json.Unmarshal(data, &object); err == nil {
		r.Content = object.Content
		return nil
	}

	var array []ToolResponseBlock
	if err := json.Unmarshal(data, &array); err != nil {
		return err
	}
	r.Content = array
	return nil
}

type HookInput struct {
	SessionID      string           `json:"session_id,omitempty"`
	TranscriptPath string           `json:"transcript_path,omitempty"`
	Model          string           `json:"model,omitempty"`
	ToolName       string           `json:"tool_name,omitempty"`
	ToolInput      json.RawMessage  `json:"tool_input,omitempty"`
	ToolResponse   HookToolResponse `json:"tool_response,omitempty"`
	Reason         string           `json:"reason,omitempty"`

	AgentID      string `json:"agent_id,omitempty"`
	AgentType    string `json:"agent_type,omitempty"`
	WorktreePath string `json:"worktree_path,omitempty"`

	MCPServerName string `json:"mcp_server_name,omitempty"`
	Mode          string `json:"mode,omitempty"`
	ElicitationID string `json:"elicitation_id,omitempty"`
	Message       string `json:"message,omitempty"`

	Action  string          `json:"action,omitempty"`
	Content json.RawMessage `json:"content,omitempty"`

	FilePath   string   `json:"file_path,omitempty"`
	MemoryType string   `json:"memory_type,omitempty"`
	LoadReason string   `json:"load_reason,omitempty"`
	Globs      []string `json:"globs,omitempty"`

	Source    string `json:"source,omitempty"`
	ToolError string `json:"tool_error,omitempty"`
	Error     string `json:"error,omitempty"`

	StopHookActive bool `json:"stop_hook_active,omitempty"`
}

type BashToolInput struct {
	Command string `json:"command"`
}

type WriteToolInput struct {
	FilePath string `json:"file_path"`
	Content  string `json:"content"`
}

type EditToolInput struct {
	FilePath  string `json:"file_path"`
	NewString string `json:"new_string"`
}

type ReadToolInput struct {
	FilePath string `json:"file_path"`
	Offset   int    `json:"offset,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}

type GlobToolInput struct {
	Pattern string `json:"pattern"`
	Path    string `json:"path"`
}

type NotebookEditToolInput struct {
	NewSource string `json:"new_source"`
}

type WebToolInput struct {
	URL   string `json:"url"`
	Query string `json:"query"`
}

type hookEnvelope struct {
	HookSpecificOutput hookSpecificOutput `json:"hookSpecificOutput"`
}

type hookSpecificOutput struct {
	HookEventName      string              `json:"hookEventName"`
	PermissionDecision string              `json:"permissionDecision,omitempty"`
	UserFacingMessage  string              `json:"userFacingMessage,omitempty"`
	UpdatedInput       *updatedInput       `json:"updatedInput,omitempty"`
	AdditionalContext  string              `json:"additionalContext,omitempty"`
	Decision           *permissionDecision `json:"decision,omitempty"`
}

type updatedInput struct {
	Command  string `json:"command,omitempty"`
	FilePath string `json:"file_path,omitempty"`
	Offset   int    `json:"offset,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}

type permissionDecision struct {
	Behavior string `json:"behavior"`
	Message  string `json:"message,omitempty"`
}

type modifyOutputEnvelope struct {
	ModifyOutput string `json:"modifyOutput"`
}

type systemMessageEnvelope struct {
	SystemMessage string `json:"systemMessage"`
}

type suppressOutputEnvelope struct {
	SuppressOutput bool `json:"suppressOutput"`
}

type stopSummaryEnvelope struct {
	StopHookSummary string `json:"stop_hook_summary"`
}

func AllowOutput() []byte {
	return SuppressOutput()
}

func DenyOutput(hookEvent, message string) []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName:      hookEvent,
		PermissionDecision: "deny",
		UserFacingMessage:  message,
	}})
}

func ModifyOutput(text string) []byte {
	return mustJSON(modifyOutputEnvelope{ModifyOutput: text})
}

func QuietOverride(modifiedCmd string) []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName:      "PreToolUse",
		PermissionDecision: "allow",
		UpdatedInput:       &updatedInput{Command: modifiedCmd},
	}})
}

func ReadReroute(filePath string, offset, limit int, ctx string) []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName:      "PreToolUse",
		PermissionDecision: "allow",
		UpdatedInput: &updatedInput{
			FilePath: filePath,
			Offset:   offset,
			Limit:    limit,
		},
		AdditionalContext: ctx,
	}})
}

func AdditionalContext(hookEvent, ctx string) []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName:     hookEvent,
		AdditionalContext: ctx,
	}})
}

func SystemMessage(msg string) []byte {
	return mustJSON(systemMessageEnvelope{SystemMessage: msg})
}

func SuppressOutput() []byte {
	return mustJSON(suppressOutputEnvelope{SuppressOutput: true})
}

func PermissionAllow() []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName: "PermissionRequest",
		Decision:      &permissionDecision{Behavior: "allow"},
	}})
}

func PermissionDeny(message string) []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{
		HookEventName: "PermissionRequest",
		Decision: &permissionDecision{
			Behavior: "deny",
			Message:  message,
		},
	}})
}

func StopSummary(summary string) []byte {
	return mustJSON(stopSummaryEnvelope{StopHookSummary: summary})
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
