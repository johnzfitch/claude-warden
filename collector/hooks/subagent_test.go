package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type subagentStartResult struct {
	HookSpecificOutput struct {
		HookEventName     string `json:"hookEventName"`
		AdditionalContext string `json:"additionalContext,omitempty"`
	} `json:"hookSpecificOutput"`
}

func TestSubagentStartGuidanceByAgentType(t *testing.T) {
	tests := []struct {
		name      string
		agentType string
		guidance  string
	}{
		{name: "explore", agentType: "Explore", guidance: exploreGuidance},
		{name: "plan", agentType: "Plan", guidance: planGuidance},
		{name: "general purpose", agentType: "general-purpose", guidance: generalPurposeGuidance},
		{name: "code reviewer", agentType: "code-reviewer", guidance: codeReviewerGuidance},
		{name: "security auditor", agentType: "security-auditor", guidance: codeReviewerGuidance},
		{name: "deep debugger", agentType: "deep-debugger", guidance: deepDebuggerGuidance},
		{name: "refactor", agentType: "refactor", guidance: workflowGuidance},
		{name: "architect", agentType: "architect", guidance: workflowGuidance},
		{name: "strategist", agentType: "strategist", guidance: workflowGuidance},
		{name: "nix expert", agentType: "nix-expert", guidance: workflowGuidance},
		{name: "git ops", agentType: "git-ops", guidance: workflowGuidance},
		{name: "test runner", agentType: "test-runner", guidance: workflowGuidance},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, collector := setupSubagentTest(t)

			out, code := handleSubagentStart(HookInput{
				AgentID:   "abc123",
				AgentType: tt.agentType,
				SessionID: "def456",
			})
			if code != 0 {
				t.Fatalf("code=%d want 0", code)
			}

			var res subagentStartResult
			if err := json.Unmarshal(out, &res); err != nil {
				t.Fatalf("unmarshal %s: %v", out, err)
			}
			if res.HookSpecificOutput.HookEventName != "SubagentStart" {
				t.Fatalf("hookEventName=%q", res.HookSpecificOutput.HookEventName)
			}
			if res.HookSpecificOutput.AdditionalContext != tt.guidance {
				t.Fatalf("additionalContext=%q want %q", res.HookSpecificOutput.AdditionalContext, tt.guidance)
			}
			if len(collector.events) != 1 {
				t.Fatalf("events=%#v", collector.events)
			}
			evt := collector.events[0]
			if evt["event_type"] != "subagent_start" || evt["agent_id"] != "abc123" || evt["agent_type"] != tt.agentType || evt["session_id"] != "def456" {
				t.Fatalf("event=%#v", evt)
			}
		})
	}
}

func TestSubagentStartUnknownTypeHasNoGuidance(t *testing.T) {
	_, collector := setupSubagentTest(t)
	unsetEnv(t, "WARDEN_CALL_LIMIT_UNKNOWN_TYPE")
	unsetEnv(t, "WARDEN_BYTE_LIMIT_UNKNOWN_TYPE")

	out, code := handleSubagentStart(HookInput{
		AgentID:   "abc123",
		AgentType: "unknown-type",
		SessionID: "def456",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["event_type"] != "subagent_start" || evt["agent_type"] != "unknown-type" {
		t.Fatalf("event=%#v", evt)
	}
	if evt["call_limit"] != float64(subagentDefaultCallLimit) || evt["byte_limit"] != float64(subagentDefaultByteLimit) {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSubagentStartBudgetLimitsFromEnv(t *testing.T) {
	_, collector := setupSubagentTest(t)
	setEnv(t, "WARDEN_CALL_LIMIT_CODE_REVIEWER", "27")
	setEnv(t, "WARDEN_BYTE_LIMIT_CODE_REVIEWER", "54321")

	out, code := handleSubagentStart(HookInput{
		AgentID:   "abc123",
		AgentType: "code-reviewer",
		SessionID: "def456",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) == 0 {
		t.Fatal("expected guidance output")
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["call_limit"] != float64(27) || evt["byte_limit"] != float64(54321) {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSubagentStartBudgetLimitsUseDefaultsWhenEnvMissing(t *testing.T) {
	_, collector := setupSubagentTest(t)
	unsetEnv(t, "WARDEN_CALL_LIMIT_EXPLORE")
	unsetEnv(t, "WARDEN_BYTE_LIMIT_EXPLORE")
	unsetEnv(t, "WARDEN_CALL_LIMIT_Explore")
	unsetEnv(t, "WARDEN_BYTE_LIMIT_Explore")

	_, code := handleSubagentStart(HookInput{
		AgentID:   "abc123",
		AgentType: "Explore",
		SessionID: "def456",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["call_limit"] != float64(subagentDefaultCallLimit) || evt["byte_limit"] != float64(subagentDefaultByteLimit) {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSubagentStartSanitizesIDs(t *testing.T) {
	home, collector := setupSubagentTest(t)
	writeFile(t, filepath.Join(home, ".claude", ".statusline", ".session_start-good-session"), "100.0\n")

	out, code := handleSubagentStart(HookInput{
		AgentID:   "",
		AgentType: "general-purpose",
		SessionID: "",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}

	var res subagentStartResult
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("unmarshal %s: %v", out, err)
	}
	if res.HookSpecificOutput.AdditionalContext != generalPurposeGuidance {
		t.Fatalf("additionalContext=%q", res.HookSpecificOutput.AdditionalContext)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["agent_id"] != "unknown" || evt["session_id"] != "" {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSubagentStopEmitsEventWithoutWorktree(t *testing.T) {
	_, collector := setupSubagentTest(t)

	out, code := handleSubagentStop(HookInput{
		AgentID:   "abc123",
		SessionID: "def456",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(out) != 0 {
		t.Fatalf("out=%q want empty", out)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["event_type"] != "subagent_stop" || evt["agent_id"] != "abc123" || evt["session_id"] != "def456" || evt["has_worktree"] != false {
		t.Fatalf("event=%#v", evt)
	}
}

func TestSubagentStopEmitsEventWithWorktree(t *testing.T) {
	_, collector := setupSubagentTest(t)

	_, code := handleSubagentStop(HookInput{
		AgentID:      "abc123",
		SessionID:    "def456",
		WorktreePath: "/tmp/worktree",
	})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	if collector.events[0]["has_worktree"] != true {
		t.Fatalf("event=%#v", collector.events[0])
	}
}

func TestSubagentStopSanitizesIDs(t *testing.T) {
	_, collector := setupSubagentTest(t)

	_, code := handleSubagentStop(HookInput{})
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	if len(collector.events) != 1 {
		t.Fatalf("events=%#v", collector.events)
	}
	evt := collector.events[0]
	if evt["agent_id"] != "unknown" || evt["session_id"] != "" || evt["has_worktree"] != false {
		t.Fatalf("event=%#v", evt)
	}
}

func setupSubagentTest(t *testing.T) (string, *recordedCollector) {
	t.Helper()
	home := t.TempDir()
	withHomeDir(t, home)
	collector := &recordedCollector{}
	prevPoster := newEventPoster
	newEventPoster = func() eventPoster { return collector }
	t.Cleanup(func() { newEventPoster = prevPoster })
	return home, collector
}

func setEnv(t *testing.T, key, value string) {
	t.Helper()
	prev, ok := os.LookupEnv(key)
	if err := os.Setenv(key, value); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(key, prev)
		} else {
			_ = os.Unsetenv(key)
		}
	})
}
