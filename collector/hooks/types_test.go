package hooks

import (
	"encoding/json"
	"testing"
)

func TestOutputBuilders(t *testing.T) {
	tests := []struct {
		name string
		got  []byte
		want string
	}{
		{"AllowOutput", AllowOutput(), `{"suppressOutput":true}`},
		{"DenyOutput", DenyOutput("PreToolUse", "reason"), `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","userFacingMessage":"reason"}}`},
		{"ModifyOutput", ModifyOutput("hello"), `{"modifyOutput":"hello"}`},
		{"QuietOverride", QuietOverride("echo hi"), `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo hi"}}}`},
		{"AdditionalContext", AdditionalContext("SessionStart", "ctx"), `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ctx"}}`},
		{"SystemMessage", SystemMessage("msg"), `{"systemMessage":"msg"}`},
		{"SuppressOutput", SuppressOutput(), `{"suppressOutput":true}`},
		{"PermissionAllow", PermissionAllow(), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`},
		{"PermissionDeny", PermissionDeny("no"), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no"}}}`},
		{"StopSummary", StopSummary("done"), `{"stop_hook_summary":"done"}`},
	}

	for _, tt := range tests {
		if string(tt.got) != tt.want {
			t.Fatalf("%s = %s, want %s", tt.name, tt.got, tt.want)
		}
		if !json.Valid(tt.got) {
			t.Fatalf("%s produced invalid JSON: %s", tt.name, tt.got)
		}
	}
}

func TestOutputBuildersEscapeStrings(t *testing.T) {
	outputs := [][]byte{
		DenyOutput("PreToolUse", `say "hi"`),
		ModifyOutput("line1\nline2"),
		QuietOverride(`printf "ok"`),
		AdditionalContext("PostToolUse", "tab\tvalue"),
		SystemMessage("x\ny"),
		PermissionDeny(`no "thanks"`),
		StopSummary("done\nnow"),
	}

	for _, output := range outputs {
		if !json.Valid(output) {
			t.Fatalf("invalid JSON: %s", output)
		}
	}
}
