package hooks

import (
	"encoding/json"
	"fmt"
	"os"
)

func init() {
	hookHandlers["config-change"] = handleConfigChange
}

func handleConfigChange(input HookInput) ([]byte, int) {
	if input.Source == "policy_settings" {
		return nil, 0
	}
	if input.FilePath == "" {
		return nil, 0
	}

	data, err := os.ReadFile(input.FilePath)
	if err != nil {
		return nil, 0
	}

	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, 0
	}

	if disabled, ok := config["disableAllHooks"].(bool); ok && disabled {
		emitConfigChangeBlocked(input, "config_disable_hooks", fmt.Sprintf("disableAllHooks in %s", input.Source))
		_, _ = fmt.Fprintf(os.Stderr, "warden: blocked config change — disableAllHooks=true in %s\n", input.FilePath)
		return nil, 2
	}

	if hooks, ok := config["hooks"]; ok && hasNonEmptyHooks(hooks) {
		if input.Source != "user_settings" {
			emitConfigChangeBlocked(input, "config_hooks_modified", fmt.Sprintf("hooks in %s", input.Source))
			_, _ = fmt.Fprintf(os.Stderr, "warden: blocked config change — hooks modified in %s (%s)\n", input.Source, input.FilePath)
			return nil, 2
		}
	}

	return nil, 0
}

func hasNonEmptyHooks(v any) bool {
	switch hooks := v.(type) {
	case map[string]any:
		return len(hooks) > 0
	case []any:
		return len(hooks) > 0
	case string:
		return hooks != ""
	default:
		return false
	}
}

func emitConfigChangeBlocked(input HookInput, rule, originalCmd string) {
	postJSONEvent(newEventPoster(), map[string]any{
		"timestamp":    relativeTimestamp(resolveSessionStart(input.SessionID)),
		"event_type":   "blocked",
		"tool":         "unknown",
		"session_id":   input.SessionID,
		"original_cmd": scrubSecrets(originalCmd),
		"rule":         rule,
		"tokens_saved": 0,
	})
}
