package hooks

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	timeNow      = time.Now
	userHomeDir  = os.UserHomeDir
	sanitizeIDRE = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)
	agentPathRE  = regexp.MustCompile(`/subagents/agent-([a-zA-Z0-9_-]+)\.jsonl$`)

	headerSecretRE = regexp.MustCompile(`(?i)(-H|--header)\s+\S+`)
	bearerSecretRE = regexp.MustCompile(`(?i)(Bearer |Authorization:\s?)[^\s]+`)
	kvSecretRE     = regexp.MustCompile(`(?i)([a-zA-Z_]*(?:key|secret|token|password|credential|api_key|database_url|client_id|client_secret|access_token|refresh_token)[a-zA-Z_]*)=[^\s]+`)
	tokenSecretRE  = regexp.MustCompile(`(?i)(ghp_|github_pat_|sk-|gho_|glpat-|xox[bpsa]-)[^\s]+`)
)

func sanitizeID(s string) string {
	if sanitizeIDRE.MatchString(s) {
		return s
	}
	return ""
}

func isSubagent(transcriptPath string) bool {
	return strings.Contains(transcriptPath, "/subagents/")
}

func getAgentID(transcriptPath string) string {
	matches := agentPathRE.FindStringSubmatch(transcriptPath)
	if len(matches) != 2 {
		return ""
	}
	return sanitizeID(matches[1])
}

func getAgentType(agentID string) string {
	agentID = sanitizeID(agentID)
	if agentID == "" {
		return ""
	}

	f, err := os.Open(filepath.Join(statuslineDir(), "subagents", agentID))
	if err != nil {
		return ""
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	for s.Scan() {
		line := s.Text()
		if strings.HasPrefix(line, "AGENT_TYPE=") {
			return strings.TrimPrefix(line, "AGENT_TYPE=")
		}
	}
	return ""
}

func resolveSessionStart(sid string) int64 {
	sid = sanitizeID(sid)
	if sid == "" {
		return timeNow().Unix()
	}

	b, err := os.ReadFile(filepath.Join(statuslineDir(), ".session_start-"+sid))
	if err != nil {
		return timeNow().Unix()
	}

	text := strings.TrimSpace(string(b))
	if text == "" {
		return timeNow().Unix()
	}

	if f, err := strconv.ParseFloat(text, 64); err == nil {
		return int64(f)
	}
	if i, err := strconv.ParseInt(text, 10, 64); err == nil {
		return i
	}
	return timeNow().Unix()
}

func relativeTimestamp(sessionStartS int64) int64 {
	return timeNow().Unix() - sessionStartS
}

func scrubSecrets(s string) string {
	s = headerSecretRE.ReplaceAllString(s, `$1 [REDACTED]`)
	s = bearerSecretRE.ReplaceAllString(s, `$1[REDACTED]`)
	s = kvSecretRE.ReplaceAllString(s, `$1=[REDACTED]`)
	s = tokenSecretRE.ReplaceAllString(s, `[REDACTED]`)
	return s
}

func getEnvInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return n
}

func getEnvStr(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func homeDir() string {
	home, err := userHomeDir()
	if err == nil && home != "" {
		return home
	}
	return os.Getenv("HOME")
}

func statuslineDir() string {
	return filepath.Join(homeDir(), ".claude", ".statusline")
}
