package hooks

import (
	"encoding/json"
	"regexp"
	"strings"
)

var (
	permissionLocalhostRE = regexp.MustCompile(`(curl|wget)[[:space:]].*https?://(localhost|127\.[0-9]|0\.0\.0\.0|\[::1\])(:[0-9]+)?`)
	permissionEnvPipeRE   = regexp.MustCompile(`^(env|printenv)[[:space:]]*\|[[:space:]]*grep[[:space:]]`)
	permissionCompoundRE  = regexp.MustCompile(`\|.*(\&\&|\|\||\;|\&[^&])`)
)

func init() {
	hookHandlers["permission-request"] = handlePermissionRequest
}

func handlePermissionRequest(input HookInput) ([]byte, int) {
	var bashInput BashToolInput
	if len(input.ToolInput) > 0 {
		_ = json.Unmarshal(input.ToolInput, &bashInput)
	}

	command := bashInput.Command
	normCommand := normalizeSpaces(command)
	if normCommand == "" {
		return SuppressOutput(), 0
	}

	switch {
	case permissionDestructiveDeny(normCommand):
		return PermissionDeny("Blocked destructive command"), 0
	case permissionForkBombDeny(normCommand):
		return PermissionDeny("Blocked fork bomb"), 0
	case permissionRCEDeny(normCommand):
		return PermissionDeny("Blocked remote code execution"), 0
	case permissionSafeCommandAllow(command):
		return PermissionAllow(), 0
	case permissionLocalhostRE.MatchString(strings.ToLower(command)):
		return PermissionAllow(), 0
	case permissionSafePipeAllow(normCommand):
		return PermissionAllow(), 0
	case permissionFilteredEnvAllow(normCommand):
		return PermissionAllow(), 0
	case permissionEchoLiteralAllow(normCommand):
		return PermissionAllow(), 0
	default:
		return SuppressOutput(), 0
	}
}

func permissionDestructiveDeny(command string) bool {
	if strings.Contains(command, "rm -rf /") ||
		strings.Contains(command, "rm -fr /") ||
		strings.Contains(command, "rm -rf ~") ||
		strings.Contains(command, "rm -fr ~") ||
		strings.Contains(command, "rm -rf --no-preserve-root") ||
		strings.Contains(command, "mkfs") ||
		strings.Contains(command, "dd if=") ||
		strings.Contains(command, "> /dev/sd") ||
		strings.Contains(command, "> /dev/nvme") ||
		strings.Contains(command, "chmod -R 777 /") {
		return true
	}

	idx := strings.Index(command, "chown -R")
	return idx >= 0 && strings.Contains(command[idx:], "/")
}

func permissionForkBombDeny(command string) bool {
	return strings.Contains(command, ":(){:|:&};:") ||
		strings.Contains(command, ":(){ :|:& };:") ||
		strings.Contains(command, ":(){ :|:&};:")
}

func permissionRCEDeny(command string) bool {
	if strings.Contains(command, "bash <(curl") ||
		strings.Contains(command, "sh <(curl") ||
		strings.Contains(command, "bash <(wget") ||
		strings.Contains(command, "sh <(wget") {
		return true
	}

	if (!strings.Contains(command, "curl") && !strings.Contains(command, "wget")) || !strings.Contains(command, "|") {
		return false
	}

	parts := splitSinglePipes(command)
	for _, part := range parts[1:] {
		fields := strings.Fields(strings.TrimLeft(part, " \t\r\n"))
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "bash", "sh":
			return true
		}
	}

	return false
}

func permissionSafeCommandAllow(command string) bool {
	return command == "whoami" ||
		command == "hostname" ||
		command == "locale" ||
		strings.HasPrefix(command, "type ") ||
		strings.HasPrefix(command, "man ")
}

func permissionSafePipeAllow(command string) bool {
	if !strings.Contains(command, "curl ") || !strings.Contains(command, "|") || permissionCompoundRE.MatchString(command) {
		return false
	}

	parts := splitSinglePipes(command)
	for _, part := range parts[1:] {
		fields := strings.Fields(strings.TrimLeft(part, " \t\r\n"))
		if len(fields) == 0 {
			continue
		}
		target := fields[0]
		if idx := strings.LastIndex(target, "/"); idx >= 0 {
			target = target[idx+1:]
		}
		switch target {
		case "bash", "sh", "zsh", "dash", "fish", "python", "python3", "node", "ruby", "perl", "eval", "exec", "source":
			return false
		}
	}

	return true
}

func permissionFilteredEnvAllow(command string) bool {
	if !permissionEnvPipeRE.MatchString(command) {
		return false
	}

	args := strings.Fields(command[strings.Index(command, "grep")+len("grep "):])
	for _, arg := range args {
		switch {
		case arg == "-f", arg == "--file", strings.HasPrefix(arg, "-f"), strings.HasPrefix(arg, "--file="):
			return false
		}
	}

	pattern := ""
	afterDashDash := false
	skipNext := false
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if skipNext {
			skipNext = false
			continue
		}
		if !afterDashDash {
			switch arg {
			case "--":
				afterDashDash = true
				continue
			case "-e", "--regexp":
				if i+1 < len(args) {
					pattern = args[i+1]
				}
				skipNext = true
				break
			case "-m", "-A", "-B", "-C", "-D", "--max-count", "--after-context", "--before-context", "--context", "--devices":
				skipNext = true
				continue
			}
			if pattern != "" {
				break
			}
			if strings.HasPrefix(arg, "--regexp=") {
				pattern = strings.TrimPrefix(arg, "--regexp=")
				break
			}
			if strings.HasPrefix(arg, "-") {
				continue
			}
		}
		pattern = arg
		break
	}

	pattern = strings.TrimPrefix(pattern, `"`)
	pattern = strings.TrimSuffix(pattern, `"`)
	pattern = strings.TrimPrefix(pattern, `'`)
	pattern = strings.TrimSuffix(pattern, `'`)

	switch pattern {
	case "", ".", ".*", "^", "^.", "^.*":
		return false
	default:
		return true
	}
}

func permissionEchoLiteralAllow(command string) bool {
	if command != "echo" && command != "echo -n" && !strings.HasPrefix(command, "echo ") && !strings.HasPrefix(command, "echo -n ") {
		return false
	}

	payload := strings.TrimPrefix(command, "echo")
	payload = strings.TrimPrefix(payload, " -n")
	payload = strings.TrimPrefix(payload, " ")

	return !strings.ContainsAny(payload, "$`\\(){}[]*?;|&<>")
}

func splitSinglePipes(s string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] != '|' {
			continue
		}
		if (i > 0 && s[i-1] == '|') || (i+1 < len(s) && s[i+1] == '|') {
			continue
		}
		parts = append(parts, s[start:i])
		start = i + 1
	}
	parts = append(parts, s[start:])
	return parts
}
