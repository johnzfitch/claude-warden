package hooks

import (
	"os"
	"strings"
)

const (
	subagentDefaultCallLimit = 30
	subagentDefaultByteLimit = 102400

	exploreGuidance        = `Pattern: tree -> Glob -> Grep -> Read. Budget: 30 calls / 80KB output. Native tools only. BATCH: issue multiple Read/Glob/Grep calls in a single response when targets are independent. OUTPUT: max 1500 tokens. Bullet list only: '- path/file.ext: one-sentence finding'. No prose preamble, no summary paragraphs, no boilerplate.`
	planGuidance           = `Pattern: structure -> patterns -> proposal. Budget: 30 calls / 80KB output. Read-only. BATCH: issue multiple Read calls in a single response. OUTPUT: max 2000 tokens. Numbered implementation steps only. No background, rationale, or 'here is my analysis' sections.`
	generalPurposeGuidance = `Pattern: explore -> plan -> execute. Budget: 35 calls / 120KB output. No MCP tools. BATCH: issue multiple independent tool calls in a single response to reduce turns. OUTPUT: max 2000 tokens. Concise results only, no narration.`
	codeReviewerGuidance   = `Pattern: scope -> grep -> read. Budget: 25-30 calls / 100KB output. Read-only. BATCH: after scoping files, Read ALL target files in a single response (up to 10 parallel Read calls). Never read files one at a time. Think once after each batch, not between each file. OUTPUT: max 2000 tokens. Bullet findings with file:line references. No praise, no boilerplate.`
	deepDebuggerGuidance   = `Pattern: reproduce -> narrow -> instrument. Budget: 40 calls / 150KB output. BATCH: issue multiple Read/Grep calls in a single response when investigating independent locations. OUTPUT: max 2000 tokens. Root cause + evidence only.`
	workflowGuidance       = `Follow agent-specific workflow. Budget: 25-35 calls / 100-120KB output. BATCH: issue multiple independent tool calls in a single response. OUTPUT: max 2000 tokens. Concise deliverables only.`
)

func init() {
	hookHandlers["subagent-start"] = handleSubagentStart
	hookHandlers["subagent-stop"] = handleSubagentStop
}

func handleSubagentStart(input HookInput) ([]byte, int) {
	agentID := sanitizeID(input.AgentID)
	if agentID == "" {
		agentID = "unknown"
	}
	sessionID := sanitizeID(input.SessionID)
	_ = resolveSessionStart(sessionID)

	callLimit, byteLimit := subagentBudgetLimits(input.AgentType)
	postJSONEvent(newEventPoster(), map[string]any{
		"event_type": "subagent_start",
		"session_id": sessionID,
		"agent_id":   agentID,
		"agent_type": input.AgentType,
		"call_limit": callLimit,
		"byte_limit": byteLimit,
	})

	if guidance := subagentGuidance(input.AgentType); guidance != "" {
		return AdditionalContext("SubagentStart", guidance), 0
	}
	return nil, 0
}

func handleSubagentStop(input HookInput) ([]byte, int) {
	agentID := sanitizeID(input.AgentID)
	if agentID == "" {
		agentID = "unknown"
	}
	sessionID := sanitizeID(input.SessionID)
	_ = resolveSessionStart(sessionID)

	postJSONEvent(newEventPoster(), map[string]any{
		"event_type":   "subagent_stop",
		"session_id":   sessionID,
		"agent_id":     agentID,
		"has_worktree": input.WorktreePath != "",
	})
	return nil, 0
}

func subagentBudgetLimits(agentType string) (int, int) {
	suffix := strings.ToUpper(strings.ReplaceAll(agentType, "-", "_"))
	callLimit := subagentEnvInt("WARDEN_CALL_LIMIT_"+suffix, subagentDefaultCallLimit)
	byteLimit := subagentEnvInt("WARDEN_BYTE_LIMIT_"+suffix, subagentDefaultByteLimit)

	legacySuffix := strings.ReplaceAll(agentType, "-", "_")
	if legacySuffix != "" && legacySuffix != suffix {
		callLimit = subagentEnvIntWithCurrent("WARDEN_CALL_LIMIT_"+legacySuffix, callLimit)
		byteLimit = subagentEnvIntWithCurrent("WARDEN_BYTE_LIMIT_"+legacySuffix, byteLimit)
	}
	return callLimit, byteLimit
}

func subagentEnvInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return getEnvInt(key, fallback)
}

func subagentEnvIntWithCurrent(key string, current int) int {
	value := os.Getenv(key)
	if value == "" {
		return current
	}
	return getEnvInt(key, current)
}

func subagentGuidance(agentType string) string {
	switch agentType {
	case "Explore":
		return exploreGuidance
	case "Plan":
		return planGuidance
	case "general-purpose":
		return generalPurposeGuidance
	case "code-reviewer", "security-auditor":
		return codeReviewerGuidance
	case "deep-debugger":
		return deepDebuggerGuidance
	case "refactor", "architect", "strategist", "nix-expert", "git-ops", "test-runner":
		return workflowGuidance
	default:
		return ""
	}
}
