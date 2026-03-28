package hooks

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type eventPoster interface {
	PostEvent([]byte)
}

var (
	newEventPoster = func() eventPoster { return NewCollectorClient() }
	pidNow         = os.Getpid

	protectedClaudePathRE  = regexp.MustCompile(`\.claude/(settings|hooks)|\.claude/settings\.(json|local\.json)`)
	homeDirPatternRE       = regexp.MustCompile(`^(/home/[^/]+|~|/Users/[^/]+|/root)/?$`)
	homeRecursivePatternRE = regexp.MustCompile(`^(/home/[^/]+|~|/Users/[^/]+|/root)/\*\*`)
	localhostWebRE         = regexp.MustCompile(`^https?://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+|0\.0\.0\.0|\[::1\])`)
	privateWebRE           = regexp.MustCompile(`^https?://(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+|192\.168\.[0-9]+)\.[0-9]+`)
	// Disk tools with sudo/doas/env prefix and absolute path support
	diskToolRE             = regexp.MustCompile(`(^|[;&|]\s*)((sudo|doas)\s+|(env\s+[A-Za-z_]+=[^\s]+\s+))*(/[^\s]*/)?` +
		`(mkfs|wipefs|fdisk|gdisk|parted|cfdisk|sfdisk|blockdev|hdparm)([\s.]|$)`)
	forkBombRE             = regexp.MustCompile(`:\(\)[[:space:]]*\{[[:space:]]*:\|:[[:space:]]*\&[[:space:]]*\}`)
	rceDirectPipeRE   = regexp.MustCompile(`\|[[:space:]]*(bash|sh|zsh|dash|python[23]?|perl|ruby|node)([[:space:];]|$)`)
	rcePathPipeRE     = regexp.MustCompile(`\|[[:space:]]*/[^[:space:]]*/+(bash|sh|zsh|dash|python[23]?|perl|ruby|node)([[:space:];]|$)`)
	rceProcSubRE      = regexp.MustCompile(`(bash|sh|zsh|dash|python[23]?|perl|ruby|node)[[:space:]]+<\((curl|wget)`)
	rceEvalRE         = regexp.MustCompile(`eval[[:space:]]+("?\$\(|'?\x60).*(curl|wget)`)
	rceSourceRE       = regexp.MustCompile(`(source|[.])[[:space:]]+<\((curl|wget)`)
	rceInterpCRE      = regexp.MustCompile(`((bash|sh|zsh|dash|python[23]?|perl|ruby|node)|/[^[:space:]]*/+(bash|sh|zsh|dash|python[23]?|perl|ruby|node))[[:space:]]+-c[[:space:]]+("?\$\(|'?\x60).*(curl|wget)`)
	rceHerestringRE   = regexp.MustCompile(`((bash|sh|zsh|dash|python[23]?|perl|ruby|node)|/[^[:space:]]*/+(bash|sh|zsh|dash|python[23]?|perl|ruby|node))[[:space:]]+<<<[[:space:]]*("?\$\(|'?\x60).*(curl|wget)`)
	envCmdRE               = regexp.MustCompile(`(^|[;&|])[[:space:]]*(env|printenv)($|[[:space:];|&])`)
	filteredEnvPipeRE      = regexp.MustCompile(`\|[[:space:]]*(grep|awk|sed|head|tail|wc)`)
	printenvSpecificRE     = regexp.MustCompile(`printenv[[:space:]]+[A-Za-z_]`)
	envAssignmentRE        = regexp.MustCompile(`env[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=`)
	bareEnvDumpRE          = regexp.MustCompile(`^[[:space:]]*(export|set|declare[[:space:]]+-x)[[:space:]]*$`)
	procEnvironRE          = regexp.MustCompile(`/proc/(self|[0-9]+)/environ`)
	curlCommandRE          = regexp.MustCompile(`(^|[;&|[:space:]])curl[[:space:]]`)
	curlVerboseRE          = regexp.MustCompile(`(^|[[:space:]])(--verbose|-v)([[:space:]]|$)`)
	curlSilentRE           = regexp.MustCompile(`(^|[[:space:]])(-s|--silent|-sS|-Ss)([[:space:]]|$)`)
	curlTimeoutRE          = regexp.MustCompile(`(-m[[:space:]]|--max-time[[:space:]]|--connect-timeout[[:space:]])`)
	wgetCommandRE          = regexp.MustCompile(`(^|[;&|[:space:]])wget[[:space:]]`)
	wgetPostRE             = regexp.MustCompile(`--post-data|--post-file`)
	curlOrWgetRE           = regexp.MustCompile(`(curl|wget)[[:space:]]`)
	localhostBashRE        = regexp.MustCompile(`(curl|wget)[[:space:]]+[^|]*https?://(localhost|127\.[0-9]|0\.0\.0\.0|\[::1\])`)
	privateBashRE          = regexp.MustCompile(`(curl|wget)[[:space:]]+[^|]*https?://(10\.[0-9]|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)`)
	curlDataUploadRE       = regexp.MustCompile(`(^|[[:space:]])(-d|--data([-=][^[:space:]]+|[[:space:]])|--data-raw([= ][^[:space:]]+)?|--data-binary([= ][^[:space:]]+)?|--data-urlencode([= ][^[:space:]]+)?|-F([[:space:]]|$)|--form([= ][^[:space:]]+)?|--upload-file([= ][^[:space:]]+)?|-T([[:space:]]|$))`)
	curlWriteMethodRE      = regexp.MustCompile(`(^|[[:space:]])-X[[:space:]]*(POST|PUT|PATCH|DELETE)([[:space:]]|$)`)
	rawSocketRE            = regexp.MustCompile(`(^|[;&|[:space:]])(nc|ncat|netcat|socat)[[:space:]]`)
	networkScanRE          = regexp.MustCompile(`(^|[;&|[:space:]])(nmap|masscan|zmap)[[:space:]]`)
	sshLikeRE              = regexp.MustCompile(`(^|[;&|[:space:]])(ssh|scp|rsync)[[:space:]]`)
	settingsRefRE          = regexp.MustCompile(`\.claude/(settings|hooks)`)
	settingsTamperCmdRE    = regexp.MustCompile(`(mv|cp|ln|tee|sed[[:space:]]+-i)[[:space:]]`)
	settingsRedirectRE     = regexp.MustCompile(`>[[:space:]]*\.claude/(settings|hooks)`)
	subagentFindRE         = regexp.MustCompile(`(^|[[:space:]]|[;&|])[[:space:]]*find[[:space:]]`)
	subagentXargsGrepRE    = regexp.MustCompile(`xargs[[:space:]]+(grep|rg)`)
	subagentBareGrepRE     = regexp.MustCompile(`(^|[;&]|&&|\|\|)[[:space:]]*grep[[:space:]]`)
	subagentLsVerboseRE    = regexp.MustCompile(`^[[:space:]]*ls[[:space:]].*(-la|-al|-lah|-lha)`)
	subagentCatGlobRE      = regexp.MustCompile(`^[[:space:]]*cat[[:space:]].*\*`)
	ffmpegRE               = regexp.MustCompile(`(^|[[:space:]|;&])ffmpeg[[:space:]]`)
	ghRunViewRE            = regexp.MustCompile(`gh[[:space:]]+run[[:space:]]+view`)
	lengthFilterRE         = regexp.MustCompile(`length <`)
	compoundAppendUnsafeRE = regexp.MustCompile(`(&&|\|\||[;<>])`)
	forceReadRE            = regexp.MustCompile(`#\s*FORCE_READ`)
	buildArtifactRE        = regexp.MustCompile(`(\.vite/build|/dist/[^/]+\.(js|css)|\.min\.(js|css)|bundle\.(js|css))`)
	metadataCmdRE          = regexp.MustCompile(`^[[:space:]]*(wc|stat|file|du|md5sum|sha256sum|sha1sum|cksum)[[:space:]]`)
	pipedOutputRE          = regexp.MustCompile(`\|[[:space:]]*(head|tail|wc|grep|awk|sed)[[:space:]]`)
	gitLogRE               = regexp.MustCompile(`^[[:space:]]*git[[:space:]]+log`)
	gitLogBoundedRE        = regexp.MustCompile(`(-n[[:space:]]*[0-9]+|-[0-9]+|--oneline|--format|--pretty|--since|--after|\|[[:space:]]*(head|tail))`)
	gitDiffRE              = regexp.MustCompile(`^[[:space:]]*git[[:space:]]+diff`)
	gitDiffBoundedRE       = regexp.MustCompile(`(--stat|--name-only|--name-status|--shortstat|--numstat|--no-color|\||&&|\|\||[;<>])`)
	catStartRE             = regexp.MustCompile(`^[[:space:]]*cat[[:space:]]`)
	catSkipRewriteRE       = regexp.MustCompile(`[|><']`)
	gitQuietRE             = regexp.MustCompile(`git[[:space:]]+(commit|clone|fetch|pull)`)
	gitQuietFlagRE         = regexp.MustCompile(`(-q|--quiet)`)
	npmQuietRE             = regexp.MustCompile(`^npm[[:space:]]+(install|i|ci)([[:space:]]|$)`)
	verboseRedirectRE      = regexp.MustCompile(`(--silent|--quiet|\||>|&)`)
	cargoBuildRE           = regexp.MustCompile(`^cargo[[:space:]]+build`)
	makeRE                 = regexp.MustCompile(`^make([[:space:]]|$)`)
	pipQuietRE             = regexp.MustCompile(`(^|python3?[[:space:]]+-m[[:space:]]+)pip3?[[:space:]]+(install|download)`)
	wgetQuietRE            = regexp.MustCompile(`^wget[[:space:]]`)
	wgetQuietFlagRE        = regexp.MustCompile(`(-q|--quiet|-O)`)
	dockerQuietRE          = regexp.MustCompile(`^docker[[:space:]]+(build|pull)`)
	dockerQuietFlagRE      = regexp.MustCompile(`(-q|--quiet|\|)`)
	grepMinifiedRE         = regexp.MustCompile(`grep`)
	grepMinifiedAllowedRE  = regexp.MustCompile(`(head[[:space:]]+-c.*\|[[:space:]]*grep|-l[[:space:]]|--files-with-matches|\|[[:space:]]*(wc|head|tail))`)
	catMinifiedRE          = regexp.MustCompile(`(cat|head|tail)[[:space:]].*(\.vite/build|/dist/[^/]+\.(js|css)|\.min\.(js|css)|bundle\.(js|css))`)
	byteLimitRE            = regexp.MustCompile(`-c[[:space:]]*[0-9]+`)
	recursiveGrepRE        = regexp.MustCompile(`(^|[[:space:];&|])grep[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|.*[[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*|.*--recursive)`)
	grepFilesWithMatchesRE = regexp.MustCompile(`(^|[[:space:]])(-[a-zA-Z]*l[a-zA-Z]*|--files-with-matches)([[:space:]]|$)`)
	pipeHeadTailWcRE       = regexp.MustCompile(`\|[[:space:]]*(head|tail|wc)`)
	recursiveFindTemplate  = `(^|[[:space:];&|])find[[:space:]].*%s`
	maxDepthOrPipeOrNameRE = regexp.MustCompile(`(-maxdepth[[:space:]]+[1-3]|\|[[:space:]]*(head|tail|wc)|-name[[:space:]])`)
	headTailRE             = regexp.MustCompile(`^[[:space:]]*(head|tail)`)
	headTailLimit1RE       = regexp.MustCompile(`-n[[:space:]]*([0-9]+)`)
	headTailLimit2RE       = regexp.MustCompile(`-([0-9]+)`)
	headTailLimit3RE       = regexp.MustCompile(`--lines=([0-9]+)`)
	largeFileCmdRE         = regexp.MustCompile(`^[[:space:]]*(cat|head|tail|less|more|bat|batcat)[[:space:]]+`)
)

func init() {
	hookHandlers["pre-tool-use"] = handlePreToolUse
}

func handlePreToolUse(input HookInput) ([]byte, int) {
	ctx := newPreToolUseContext(input)
	ctx.emitMCPToolStart()
	ctx.loadSubagentInfo()
	if output, ok := ctx.enforceSubagentBudget(); ok {
		return output, 0
	}

	switch input.ToolName {
	case "Write":
		return ctx.handleWrite(), 0
	case "Edit":
		return ctx.handleEdit(), 0
	case "NotebookEdit":
		return ctx.handleNotebookEdit(), 0
	case "Glob":
		return ctx.handleGlob(), 0
	case "WebFetch", "WebSearch":
		return ctx.handleWebTool(), 0
	case "Bash":
	default:
		return preToolUseAllow(), 0
	}

	if ctx.command == "" {
		return preToolUseAllow(), 0
	}

	if output, ok := ctx.handleBash(); ok {
		return output, 0
	}
	return preToolUseAllow(), 0
}

type preToolUseContext struct {
	input         HookInput
	command       string
	normCommand   string
	sessionStartS int64
	isSubagent    bool
	agentID       string
	agentType     string
	collector     eventPoster
}

func newPreToolUseContext(input HookInput) *preToolUseContext {
	ctx := &preToolUseContext{input: input, sessionStartS: resolveSessionStart(input.SessionID), collector: newEventPoster()}
	var bashInput BashToolInput
	if len(input.ToolInput) > 0 && json.Unmarshal(input.ToolInput, &bashInput) == nil {
		ctx.command = bashInput.Command
	}
	ctx.normCommand = normalizeSpaces(ctx.command)
	return ctx
}

func (c *preToolUseContext) handleWrite() []byte {
	var in WriteToolInput
	_ = json.Unmarshal(c.input.ToolInput, &in)
	maxBytes := getEnvInt("WARDEN_WRITE_MAX_BYTES", 51200)
	if len(in.Content) > maxBytes {
		c.emitBlocked("write_oversize", 25000, fmt.Sprintf("Write %dB → %s", len(in.Content), in.FilePath))
		return c.deny(fmt.Sprintf("Write >%dB (>%dKB)", len(in.Content), maxBytes/1024))
	}
	if protectedClaudePathRE.MatchString(in.FilePath) {
		c.emitBlocked("settings_write", 0, fmt.Sprintf("Write → %s", in.FilePath))
		return c.deny(fmt.Sprintf("Sandbox violation: Write to %s blocked. Claude settings and hook files are protected from model writes.", in.FilePath))
	}
	return preToolUseAllow()
}

func (c *preToolUseContext) handleEdit() []byte {
	var in EditToolInput
	_ = json.Unmarshal(c.input.ToolInput, &in)
	maxBytes := getEnvInt("WARDEN_EDIT_MAX_BYTES", 25600)
	if len(in.NewString) > maxBytes {
		c.emitBlocked("edit_oversize", 12500, fmt.Sprintf("Edit %dB → %s", len(in.NewString), in.FilePath))
		return c.deny(fmt.Sprintf("Edit >%dB (>%dKB)", len(in.NewString), maxBytes/1024))
	}
	if protectedClaudePathRE.MatchString(in.FilePath) {
		c.emitBlocked("settings_edit", 0, fmt.Sprintf("Edit → %s", in.FilePath))
		return c.deny(fmt.Sprintf("Sandbox violation: Edit to %s blocked. Claude settings and hook files are protected from model edits.", in.FilePath))
	}
	return preToolUseAllow()
}

func (c *preToolUseContext) handleNotebookEdit() []byte {
	var in NotebookEditToolInput
	_ = json.Unmarshal(c.input.ToolInput, &in)
	maxBytes := getEnvInt("WARDEN_NOTEBOOK_MAX_BYTES", 25600)
	if len(in.NewSource) > maxBytes {
		c.emitBlocked("notebook_oversize", 12500, fmt.Sprintf("NotebookEdit %dB", len(in.NewSource)))
		return c.deny(fmt.Sprintf("NotebookEdit >%dB (>%dKB)", len(in.NewSource), maxBytes/1024))
	}
	return preToolUseAllow()
}

func (c *preToolUseContext) handleGlob() []byte {
	var in GlobToolInput
	_ = json.Unmarshal(c.input.ToolInput, &in)
	if strings.Contains(in.Pattern, "**") {
		globPath := in.Path
		if homeDirPatternRE.MatchString(globPath) || (globPath == "" && homeDirPatternRE.MatchString(os.Getenv("PWD"))) {
			c.emitBlocked("glob_home_recursive", 5000, fmt.Sprintf("Glob %s in %s", in.Pattern, globPath))
			return c.deny("Glob ** in home dir; narrow path or use fd")
		}
		if homeRecursivePatternRE.MatchString(in.Pattern) {
			c.emitBlocked("glob_home_recursive", 5000, fmt.Sprintf("Glob %s", in.Pattern))
			return c.deny("Glob ** in home dir; narrow path or use fd")
		}
	}
	return preToolUseAllow()
}

func (c *preToolUseContext) handleWebTool() []byte {
	var in WebToolInput
	_ = json.Unmarshal(c.input.ToolInput, &in)
	url := in.URL
	if url == "" {
		url = in.Query
	}
	lower := strings.ToLower(url)
	if isMetadataURL(lower) {
		c.emitBlocked("ssrf_metadata", 0, fmt.Sprintf("%s %s", c.input.ToolName, url))
		return c.deny(fmt.Sprintf("Network boundary violation: %s tried to reach cloud metadata endpoint (%s). This is a protected internal address that exposes instance credentials.", c.input.ToolName, url))
	}
	if localhostWebRE.MatchString(lower) {
		c.emitBlocked("ssrf_localhost", 0, fmt.Sprintf("%s %s", c.input.ToolName, url))
		return c.deny(fmt.Sprintf("Network boundary violation: %s tried to reach localhost (%s). This tool cannot access local services. Run the local request directly in your terminal and share the relevant output, or read specific log files.", c.input.ToolName, url))
	}
	if privateWebRE.MatchString(lower) {
		c.emitBlocked("ssrf_private", 0, fmt.Sprintf("%s %s", c.input.ToolName, url))
		return c.deny(fmt.Sprintf("Network boundary violation: %s tried to reach private network (%s). Internal network access is not allowed via %s.", c.input.ToolName, url, c.input.ToolName))
	}
	c.emitAllowed("web_access")
	return preToolUseAllow()
}

func (c *preToolUseContext) handleBash() ([]byte, bool) {
	if out, ok := c.checkDestructive(); ok {
		return out, true
	}
	if out, ok := c.checkForkBomb(); ok {
		return out, true
	}
	if out, ok := c.checkRCE(); ok {
		return out, true
	}
	if out, ok := c.checkEnvDump(); ok {
		return out, true
	}
	if out, ok := c.checkWgetPost(); ok {
		return out, true
	}
	if out, ok := c.checkBashSSRF(); ok {
		return out, true
	}
	if out, ok := c.checkCurlSanitize(); ok {
		return out, true
	}
	if out, ok := c.checkRawSockets(); ok {
		return out, true
	}
	if out, ok := c.checkNetworkScans(); ok {
		return out, true
	}
	if out, ok := c.checkSSH(); ok {
		return out, true
	}
	if out, ok := c.checkSettingsTampering(); ok {
		return out, true
	}
	if out, ok := c.checkSubagentBashBlocks(); ok {
		return out, true
	}
	if out, ok := c.checkFFmpeg(); ok {
		return out, true
	}
	if out, ok := c.checkGHRunView(); ok {
		return out, true
	}
	if forceReadRE.MatchString(c.command) {
		return preToolUseAllow(), true
	}

	isBuildArtifact := buildArtifactRE.MatchString(c.command)
	if metadataCmdRE.MatchString(c.command) {
		return preToolUseAllow(), true
	}
	if !isBuildArtifact && pipedOutputRE.MatchString(c.command) {
		return preToolUseAllow(), true
	}
	if out, ok := c.checkGitLog(); ok {
		return out, true
	}
	if out, ok := c.checkGitDiff(); ok {
		return out, true
	}
	if out, ok := c.checkCatRewrite(); ok {
		return out, true
	}
	if out, ok := c.checkGitQuiet(); ok {
		return out, true
	}
	if out, ok := c.checkVerboseQuietOverrides(); ok {
		return out, true
	}
	if out, ok := c.checkBuildArtifacts(isBuildArtifact); ok {
		return out, true
	}
	if out, ok := c.checkRecursiveGrep(); ok {
		return out, true
	}
	if out, ok := c.checkRecursiveFind(); ok {
		return out, true
	}
	if out, ok := c.checkBoundedHeadTail(); ok {
		return out, true
	}
	if byteLimitRE.MatchString(c.command) {
		return preToolUseAllow(), true
	}
	if out, ok := c.checkLargeFiles(); ok {
		return out, true
	}
	return nil, false
}

func (c *preToolUseContext) emitMCPToolStart() {
	if !strings.HasPrefix(c.input.ToolName, "mcp__") {
		return
	}
	stripped := strings.TrimPrefix(c.input.ToolName, "mcp__")
	server := stripped
	tool := ""
	if i := strings.Index(stripped, "__"); i >= 0 {
		server = stripped[:i]
		tool = stripped[i+2:]
	}
	c.postJSON(map[string]any{
		"timestamp":  relativeTimestamp(c.sessionStartS),
		"event_type": "mcp_tool_start",
		"tool":       c.input.ToolName,
		"mcp_server": server,
		"mcp_tool":   tool,
	})
}

func (c *preToolUseContext) loadSubagentInfo() {
	c.isSubagent = strings.Contains(c.input.TranscriptPath, "/subagents/")
	c.agentID = getAgentID(c.input.TranscriptPath)
	if c.agentID != "" {
		c.agentType = getAgentType(c.agentID)
	}
}

func (c *preToolUseContext) enforceSubagentBudget() ([]byte, bool) {
	if !c.isSubagent || c.agentID == "" {
		return nil, false
	}
	denyFile := filepath.Join(stateDir(), "budget-deny-"+c.agentID)
	if b, err := os.ReadFile(denyFile); err == nil {
		reason := strings.TrimSpace(string(b))
		if reason == "" {
			reason = "limit reached"
		}
		c.emitBlocked("budget_exceeded", 2000, "")
		return c.deny("Budget exceeded: " + reason + ". Stop and report findings."), true
	}
	c.postJSON(map[string]any{
		"event_type": "subagent_tool_call",
		"agent_id":   c.agentID,
		"session_id": c.input.SessionID,
		"tool":       c.input.ToolName,
	})
	return nil, false
}

func (c *preToolUseContext) checkDestructive() ([]byte, bool) {
	// Content-position patterns (safe from false positives in grep args)
	patterns := []string{
		"rm -rf /", "rm -fr /", "rm -rf ~", "rm -fr ~", "rm -rf .", "rm -fr .",
		"rm -rf *", "rm -fr *", "rm --recursive --force", "rm --force --recursive",
		"rm -rf --no-preserve-root", "dd if=", "dd of=/dev/", "> /dev/sd",
		"> /dev/nvme", "chmod -R 777 /", "chown -R", "chown --recursive",
	}
	for _, p := range patterns {
		if strings.Contains(c.normCommand, p) {
			c.emitBlocked("destructive_cmd", 0, "")
			return c.deny("Blocked destructive command"), true
		}
	}
	// Disk tools: command-position regex with sudo/doas/env prefix + absolute path support
	if diskToolRE.MatchString(c.normCommand) {
		c.emitBlocked("destructive_cmd", 0, "")
		return c.deny("Blocked destructive command"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkForkBomb() ([]byte, bool) {
	if forkBombRE.MatchString(c.normCommand) {
		c.emitBlocked("fork_bomb", 0, "")
		return c.deny("Blocked fork bomb"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkRCE() ([]byte, bool) {
	if !strings.Contains(c.normCommand, "curl") && !strings.Contains(c.normCommand, "wget") {
		return nil, false
	}
	if rceDirectPipeRE.MatchString(c.normCommand) || rcePathPipeRE.MatchString(c.normCommand) || rceProcSubRE.MatchString(c.normCommand) {
		c.emitBlocked("rce_pipe", 0, "")
		return c.deny("Blocked remote code execution"), true
	}
	if rceEvalRE.MatchString(c.normCommand) {
		c.emitBlocked("rce_eval", 0, "")
		return c.deny("Blocked remote code execution"), true
	}
	if rceSourceRE.MatchString(c.normCommand) {
		c.emitBlocked("rce_source", 0, "")
		return c.deny("Blocked remote code execution"), true
	}
	if rceInterpCRE.MatchString(c.normCommand) {
		c.emitBlocked("rce_exec_c", 0, "")
		return c.deny("Blocked remote code execution"), true
	}
	if rceHerestringRE.MatchString(c.normCommand) {
		c.emitBlocked("rce_herestring", 0, "")
		return c.deny("Blocked remote code execution"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkEnvDump() ([]byte, bool) {
	if envCmdRE.MatchString(c.command) && !filteredEnvPipeRE.MatchString(c.command) && !printenvSpecificRE.MatchString(c.command) && !envAssignmentRE.MatchString(c.command) {
		c.emitBlocked("env_dump", 0, "")
		return c.deny(fmt.Sprintf("Environment safety: '%s' dumps all environment variables including API keys and tokens into conversation context. Query specific variables instead: echo $VAR_NAME, or filter: env | grep PATTERN", truncateString(c.command, 60))), true
	}
	if bareEnvDumpRE.MatchString(c.command) {
		c.emitBlocked("env_dump", 0, "")
		return c.deny(fmt.Sprintf("Environment safety: '%s' dumps all environment variables. Query specific variables instead: echo $VAR_NAME", truncateString(c.command, 60))), true
	}
	if procEnvironRE.MatchString(c.command) {
		c.emitBlocked("env_dump_proc", 0, "")
		return c.deny(fmt.Sprintf("Environment safety: '%s' reads raw process environment containing all secrets. Query specific variables instead: echo $VAR_NAME", truncateString(c.command, 80))), true
	}
	return nil, false
}

func (c *preToolUseContext) checkCurlSanitize() ([]byte, bool) {
	loc := curlCommandRE.FindStringSubmatchIndex(c.command)
	if loc == nil {
		return nil, false
	}
	prefix := c.command[loc[2]:loc[3]]
	clean := curlVerboseRE.ReplaceAllString(c.command, `$1$3`)
	if !curlSilentRE.MatchString(clean) {
		clean = strings.Replace(clean, prefix+"curl ", prefix+"curl -sS ", 1)
	}
	if !curlTimeoutRE.MatchString(clean) {
		clean = strings.Replace(clean, prefix+"curl ", prefix+"curl --max-time 30 ", 1)
	}
	if clean != c.command {
		return c.quietOverride("curl_sanitized", clean), true
	}
	return nil, false
}

func (c *preToolUseContext) checkWgetPost() ([]byte, bool) {
	if wgetCommandRE.MatchString(c.command) && wgetPostRE.MatchString(c.command) {
		c.emitBlocked("data_exfil_wget", 0, "wget with POST data")
		return c.deny(fmt.Sprintf("Data upload blocked: '%s' sends data to a remote server. wget with --post-data/--post-file is restricted. Ask the user to run this manually if needed.", truncateString(c.command, 120))), true
	}
	return nil, false
}

func (c *preToolUseContext) checkBashSSRF() ([]byte, bool) {
	if !curlOrWgetRE.MatchString(c.command) {
		return nil, false
	}
	lower := strings.ToLower(c.command)
	if isMetadataURL(lower) {
		c.emitBlocked("ssrf_metadata_bash", 0, "")
		return c.deny(fmt.Sprintf("Network boundary violation: '%s' targets a cloud metadata endpoint. These addresses expose instance credentials and are never safe to query from model context.", truncateString(c.command, 120))), true
	}
	// Note: localhost via Bash curl is ALLOWED (used for collector, Ollama, etc.)
	// Only WebFetch/WebSearch block localhost (in handleWebTool).
	if privateBashRE.MatchString(lower) {
		c.emitBlocked("ssrf_private_bash", 0, "")
		return c.deny(fmt.Sprintf("Network boundary violation: '%s' targets a private network address. Internal network access via curl/wget is not allowed. Ask the user to provide the data or check specific files.", truncateString(c.command, 120))), true
	}
	if !localhostBashRE.MatchString(lower) && (curlDataUploadRE.MatchString(c.command) || curlWriteMethodRE.MatchString(strings.ToUpper(c.command))) {
		c.emitBlocked("data_exfil_curl", 0, "")
		return c.deny(fmt.Sprintf("Data upload blocked: '%s' sends data to a remote server. Upload flags and write methods are restricted for curl/wget.", truncateString(c.command, 120))), true
	}
	return nil, false
}

func (c *preToolUseContext) checkRawSockets() ([]byte, bool) {
	if m := rawSocketRE.FindStringSubmatch(c.command); len(m) > 2 {
		c.emitBlocked("raw_socket", 0, "")
		return c.deny(fmt.Sprintf("Network safety: '%s' uses raw socket tool %s. Raw socket connections (nc/ncat/netcat/socat) are not permitted. Use curl for HTTP or ssh for remote access.", truncateString(c.command, 80), m[2])), true
	}
	return nil, false
}

func (c *preToolUseContext) checkNetworkScans() ([]byte, bool) {
	if m := networkScanRE.FindStringSubmatch(c.command); len(m) > 2 {
		c.emitBlocked("network_scan", 0, "")
		return c.deny(fmt.Sprintf("Network safety: '%s' runs network scanner %s. Port scanning and network enumeration are not permitted from model context.", truncateString(c.command, 80), m[2])), true
	}
	return nil, false
}

func (c *preToolUseContext) checkSSH() ([]byte, bool) {
	if m := sshLikeRE.FindStringSubmatch(c.command); len(m) > 2 {
		if c.isSubagent {
			c.emitBlocked("subagent_network", 0, "")
			return c.deny(fmt.Sprintf("Subagent boundary: '%s' uses %s which requires network access. Subagents cannot use ssh/scp/rsync. Return this task to the main agent.", truncateString(c.command, 80), m[2])), true
		}
		c.emitAllowed("network_ssh")
	}
	return nil, false
}

func (c *preToolUseContext) checkSettingsTampering() ([]byte, bool) {
	if !settingsRefRE.MatchString(c.command) {
		return nil, false
	}
	// Redirects and in-place modifiers: always block
	if settingsRedirectRE.MatchString(c.command) {
		c.emitBlocked("settings_tamper_bash", 0, "")
		return c.deny(fmt.Sprintf("Sandbox violation: '%s' modifies Claude settings or hook files. These files are protected.", truncateString(c.command, 100))), true
	}
	if regexp.MustCompile(`(tee|sed\s+-i)\s`).MatchString(c.command) {
		c.emitBlocked("settings_tamper_bash", 0, "")
		return c.deny(fmt.Sprintf("Sandbox violation: '%s' modifies Claude settings or hook files. These files are protected.", truncateString(c.command, 100))), true
	}
	// cp/mv/ln: allow if settings path is clearly the source (backup/read)
	if m := regexp.MustCompile(`(cp|mv|ln)\s`).FindString(c.command); m != "" {
		cmd := strings.TrimSpace(m)
		// Extract the portion after the command
		idx := strings.Index(c.command, m)
		portion := c.command[idx+len(m):]
		// Parse non-flag args, stop at shell metacharacters
		var args []string
		for _, w := range strings.Fields(portion) {
			if strings.HasPrefix(w, "-") {
				continue
			}
			if strings.ContainsAny(w, ";&|>") {
				break
			}
			args = append(args, w)
		}
		if len(args) == 2 {
			src, dest := args[0], args[1]
			if settingsRefRE.MatchString(src) && !settingsRefRE.MatchString(dest) {
				// Source is settings, dest is not — backup/read, allow
				return nil, false
			}
		}
		_ = cmd
		c.emitBlocked("settings_tamper_bash", 0, "")
		return c.deny(fmt.Sprintf("Sandbox violation: '%s' writes to Claude settings or hook files.", truncateString(c.command, 100))), true
	}
	return nil, false
}

func (c *preToolUseContext) checkSubagentBashBlocks() ([]byte, bool) {
	if !c.isSubagent {
		return nil, false
	}
	if subagentFindRE.MatchString(c.command) {
		c.emitBlocked("subagent_find", 3000, "")
		return c.deny("Use Glob tool instead of find"), true
	}
	if subagentXargsGrepRE.MatchString(c.command) {
		c.emitBlocked("subagent_xargs_grep", 5000, "")
		return c.deny("Use Grep tool instead of xargs grep"), true
	}
	if subagentBareGrepRE.MatchString(c.command) {
		c.emitBlocked("subagent_grep", 5000, "")
		return c.deny("Use Grep tool or rg instead of grep"), true
	}
	if subagentLsVerboseRE.MatchString(c.command) {
		c.emitBlocked("subagent_ls_verbose", 2000, "")
		return c.deny("Use tree -L 2 or Glob tool instead of ls -la"), true
	}
	if subagentCatGlobRE.MatchString(c.command) {
		c.emitBlocked("subagent_cat_glob", 10000, "")
		return c.deny("Use Glob then Read for pattern-matched files"), true
	}
	if regexp.MustCompile(`^[[:space:]]*cat[[:space:]].*[[:space:]]`).MatchString(c.command) && !strings.Contains(c.command, "|") {
		count := 0
		for _, arg := range strings.Fields(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(c.command), "cat"))) {
			if !strings.HasPrefix(arg, "-") {
				count++
			}
		}
		if count > 2 {
			c.emitBlocked("subagent_cat_multi", 5000, "")
			return c.deny("Use Read tool for multiple files (parallel)"), true
		}
	}
	return nil, false
}

func (c *preToolUseContext) checkFFmpeg() ([]byte, bool) {
	if ffmpegRE.MatchString(c.command) && !strings.Contains(c.command, "-nostats") {
		quiet := ffmpegRE.ReplaceAllString(c.command, `${1}ffmpeg -nostats -loglevel error `)
		return c.quietOverride("ffmpeg_quiet_override", quiet), true
	}
	return nil, false
}

func (c *preToolUseContext) checkGHRunView() ([]byte, bool) {
	if ghRunViewRE.MatchString(c.command) && strings.Contains(c.command, "--log-failed") && !lengthFilterRE.MatchString(c.command) && !compoundAppendUnsafeRE.MatchString(c.command) {
		quiet := regexp.MustCompile(`[[:space:]]*2>&1[[:space:]]*\|[[:space:]]*tail[[:space:]]+-[0-9]+`).ReplaceAllString(c.command, "")
		quiet += " 2>&1 | awk 'length < 400' | tail -25"
		return c.quietOverride("gh_run_view_log_filter", quiet), true
	}
	return nil, false
}

func (c *preToolUseContext) checkGitLog() ([]byte, bool) {
	if gitLogRE.MatchString(c.command) && !gitLogBoundedRE.MatchString(c.command) {
		c.emitBlocked("git_log_unbounded", 10000, "")
		return c.deny("git log needs -n, --oneline, or pipe"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkGitDiff() ([]byte, bool) {
	if gitDiffRE.MatchString(c.command) && !gitDiffBoundedRE.MatchString(c.command) {
		return c.quietOverride("git_diff_bounded", c.command+" --no-color | head -200"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkCatRewrite() ([]byte, bool) {
	if !catStartRE.MatchString(c.command) || catSkipRewriteRE.MatchString(c.command) || c.isSubagent {
		return nil, false
	}
	args := strings.Fields(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(c.command), "cat")))
	fileCount := 0
	catFile := ""
	for _, arg := range args {
		if strings.HasPrefix(arg, "-") {
			continue
		}
		fileCount++
		if catFile == "" {
			catFile = arg
		}
	}
	if fileCount != 1 || catFile == "" {
		return nil, false
	}
	expanded := expandTilde(catFile)
	fi, err := os.Stat(expanded)
	if err != nil || fi.IsDir() || fi.Size() <= 8192 {
		return nil, false
	}
	if fi.Size() > 1048576 {
		return nil, false
	}
	if _, binary := detectBinaryFile(expanded); binary {
		return nil, false
	}
	quiet := fmt.Sprintf("head -c 8192 %q && echo '\n[warden: cat -> head -c 8192 (%dKB file). Use Read with offset/limit for full content.]'", catFile, fi.Size()/1024)
	return c.quietOverride("cat_to_head", quiet), true
}

func (c *preToolUseContext) checkGitQuiet() ([]byte, bool) {
	if gitQuietRE.MatchString(c.command) && !gitQuietFlagRE.MatchString(c.command) {
		quiet := regexp.MustCompile(`(git[[:space:]]+(commit|clone|fetch|pull))`).ReplaceAllString(c.command, `${1} -q`)
		return c.quietOverride("git_quiet_override", quiet), true
	}
	return nil, false
}

func (c *preToolUseContext) checkVerboseQuietOverrides() ([]byte, bool) {
	if npmQuietRE.MatchString(c.command) && !verboseRedirectRE.MatchString(c.command) {
		quiet := regexp.MustCompile(`^(npm[[:space:]]+(install|i|ci))`).ReplaceAllString(c.command, `${1} --silent`)
		return c.quietOverride("npm_quiet_override", quiet), true
	}
	if cargoBuildRE.MatchString(c.command) && !regexp.MustCompile(`(-q|--quiet|\||>|&)`).MatchString(c.command) {
		quiet := regexp.MustCompile(`^(cargo[[:space:]]+build)`).ReplaceAllString(c.command, `${1} -q`)
		return c.quietOverride("cargo_quiet_override", quiet), true
	}
	if makeRE.MatchString(c.command) && !regexp.MustCompile(`(-s|--silent|\||>|&)`).MatchString(c.command) {
		quiet := regexp.MustCompile(`^make`).ReplaceAllString(c.command, `make -s`)
		return c.quietOverride("make_quiet_override", quiet), true
	}
	if pipQuietRE.MatchString(c.command) && !regexp.MustCompile(`(-q|--quiet)`).MatchString(c.command) {
		quiet := regexp.MustCompile(`(pip3?[[:space:]]+(install|download))`).ReplaceAllString(c.command, `${1} -q`)
		return c.quietOverride("pip_quiet_override", quiet), true
	}
	if wgetQuietRE.MatchString(c.command) && !wgetQuietFlagRE.MatchString(c.command) {
		quiet := regexp.MustCompile(`^wget`).ReplaceAllString(c.command, `wget -q`)
		return c.quietOverride("wget_quiet_override", quiet), true
	}
	if dockerQuietRE.MatchString(c.command) && !dockerQuietFlagRE.MatchString(c.command) {
		quiet := regexp.MustCompile(`^(docker[[:space:]]+(build|pull))`).ReplaceAllString(c.command, `${1} -q`)
		return c.quietOverride("docker_quiet_override", quiet), true
	}
	return nil, false
}

func (c *preToolUseContext) checkBuildArtifacts(isBuildArtifact bool) ([]byte, bool) {
	if !isBuildArtifact {
		return nil, false
	}
	if grepMinifiedRE.MatchString(c.command) && !grepMinifiedAllowedRE.MatchString(c.command) {
		c.emitBlocked("grep_minified", 25000, "")
		return c.deny("grep on minified file; use Grep tool or pipe head -c first"), true
	}
	if catMinifiedRE.MatchString(c.command) && !byteLimitRE.MatchString(c.command) {
		c.emitBlocked("cat_minified", 25000, "")
		return c.deny("Minified file; use head -c 4000"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkRecursiveGrep() ([]byte, bool) {
	if !c.isSubagent && recursiveGrepRE.MatchString(c.command) && !grepFilesWithMatchesRE.MatchString(c.command) && !pipeHeadTailWcRE.MatchString(c.command) {
		c.emitBlocked("grep_recursive", 10000, "")
		return c.deny("grep -r scans all - use rg or grep -l"), true
	}
	return nil, false
}

func (c *preToolUseContext) checkRecursiveFind() ([]byte, bool) {
	for _, item := range []struct {
		pattern string
		display string
	}{
		{pattern: `\.claude`, display: `.claude`},
		{pattern: `\.git`, display: `.git`},
		{pattern: `node_modules`, display: `node_modules`},
	} {
		re := regexp.MustCompile(fmt.Sprintf(recursiveFindTemplate, item.pattern))
		if re.MatchString(c.command) && !maxDepthOrPipeOrNameRE.MatchString(c.command) {
			c.emitBlocked("find_recursive", 5000, "")
			return c.deny("find in " + item.display + " needs -maxdepth or pipe"), true
		}
	}
	return nil, false
}

func (c *preToolUseContext) checkBoundedHeadTail() ([]byte, bool) {
	if !headTailRE.MatchString(c.command) {
		return nil, false
	}
	for _, re := range []*regexp.Regexp{headTailLimit1RE, headTailLimit2RE, headTailLimit3RE} {
		if m := re.FindStringSubmatch(c.command); len(m) > 1 {
			if n, err := strconv.Atoi(m[1]); err == nil && n <= 500 {
				return preToolUseAllow(), true
			}
		}
	}
	return nil, false
}

func (c *preToolUseContext) checkLargeFiles() ([]byte, bool) {
	m := largeFileCmdRE.FindString(c.command)
	if m == "" {
		return nil, false
	}
	rest := strings.TrimPrefix(c.command, m)
	for _, arg := range strings.Fields(rest) {
		switch arg {
		case "|", "&&", ";", "||", ">", ">>", "<", "&":
			return nil, false
		}
		if strings.HasPrefix(arg, "-") {
			continue
		}
		expanded := expandTilde(arg)
		fi, err := os.Stat(expanded)
		if err != nil || fi.IsDir() {
			continue
		}
		if fileType, binary := detectBinaryFile(expanded); binary {
			c.emitBlocked("binary_file", 10000, "")
			return c.deny(expanded + " is binary (" + fileType + "). Use file, xxd, or hexdump"), true
		}
		if fi.Size() > 1048576 {
			c.emitBlocked("large_file", int(fi.Size()/4), "")
			return c.deny(fmt.Sprintf("%s is %dKB (>1MB). Use head -c 4000", expanded, fi.Size()/1024)), true
		}
	}
	return nil, false
}

func (c *preToolUseContext) quietOverride(rule, command string) []byte {
	c.writeQuietOverrideState(rule, command)
	c.emitAllowed(rule)
	return QuietOverride(command)
}

func (c *preToolUseContext) writeQuietOverrideState(rule, command string) {
	tool := c.input.ToolName
	if tool == "" {
		tool = "Bash"
	}
	sid := c.input.SessionID
	if sid == "" {
		sid = strconv.Itoa(pidNow())
	}
	h := md5.Sum([]byte(command))
	cmdHash := hex.EncodeToString(h[:])
	name := fmt.Sprintf(".quiet-override-%s-%s-%s-%d-%d", tool, sid, cmdHash, timeNow().UnixNano(), pidNow())
	_ = os.MkdirAll(statuslineDir(), 0o755)
	_ = os.WriteFile(filepath.Join(statuslineDir(), name), []byte(rule), 0o644)
}

func (c *preToolUseContext) emitBlocked(rule string, tokensSaved int, cmdOverride string) {
	cmd := cmdOverride
	if cmd == "" {
		cmd = truncateString(c.command, 200)
	}
	c.postJSON(map[string]any{
		"timestamp":    relativeTimestamp(c.sessionStartS),
		"event_type":   "blocked",
		"tool":         c.input.ToolNameOrDefault(),
		"session_id":   c.input.SessionID,
		"original_cmd": scrubSecrets(cmd),
		"rule":         rule,
		"tokens_saved": tokensSaved,
	})
}

func (c *preToolUseContext) emitAllowed(rule string) {
	c.postJSON(map[string]any{
		"timestamp":             relativeTimestamp(c.sessionStartS),
		"event_type":            "allowed",
		"tool":                  c.input.ToolNameOrDefault(),
		"session_id":            c.input.SessionID,
		"original_cmd":          scrubSecrets(truncateString(c.command, 200)),
		"tokens_saved":          0,
		"original_output_bytes": 0,
		"final_output_bytes":    0,
		"rule":                  rule,
	})
}

func (c *preToolUseContext) postJSON(v any) {
	if c.collector == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.collector.PostEvent(b)
}

func (c *preToolUseContext) deny(reason string) []byte {
	return DenyOutput("PreToolUse", reason)
}

func (in HookInput) ToolNameOrDefault() string {
	if in.ToolName == "" {
		return "unknown"
	}
	return in.ToolName
}

func preToolUseAllow() []byte {
	return mustJSON(hookEnvelope{HookSpecificOutput: hookSpecificOutput{HookEventName: "PreToolUse", PermissionDecision: "allow"}})
}

func normalizeSpaces(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

func truncateString(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func isMetadataURL(s string) bool {
	return strings.Contains(s, "169.254.169.254") || strings.Contains(s, "metadata.google.internal") || strings.Contains(s, "169.254.169.250") || strings.Contains(s, "100.100.100.200")
}

func nonLocalhostHTTPURL(s string) bool {
	for _, tok := range strings.Fields(s) {
		if strings.HasPrefix(tok, "http://") || strings.HasPrefix(tok, "https://") {
			if localhostWebRE.MatchString(tok) {
				return false
			}
			return true
		}
	}
	return false
}

func expandTilde(s string) string {
	if s == "~" {
		return homeDir()
	}
	if strings.HasPrefix(s, "~/") {
		return filepath.Join(homeDir(), strings.TrimPrefix(s, "~/"))
	}
	return s
}

func detectBinaryFile(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	buf := make([]byte, 512)
	n, _ := f.Read(buf)
	buf = buf[:n]
	if len(buf) == 0 {
		return "", false
	}
	if bytes.HasPrefix(buf, []byte{0x7f, 'E', 'L', 'F'}) {
		return "ELF", true
	}
	if bytes.HasPrefix(buf, []byte("MZ")) {
		return "PE32", true
	}
	if isMachO(buf) {
		return "Mach-O", true
	}
	if bytes.HasPrefix(buf, []byte{0x1f, 0x8b}) {
		return "gzip", true
	}
	if bytes.HasPrefix(buf, []byte("PK\x03\x04")) || bytes.HasPrefix(buf, []byte("PK\x05\x06")) || bytes.HasPrefix(buf, []byte("PK\x07\x08")) {
		return "Zip", true
	}
	if bytes.HasPrefix(buf, []byte("%PDF-")) {
		return "PDF", true
	}
	if bytes.HasPrefix(buf, []byte("SQLite format 3\x00")) {
		return "SQLite", true
	}
	ctype := http.DetectContentType(buf)
	if strings.HasPrefix(ctype, "image/") {
		return "image", true
	}
	if strings.HasPrefix(ctype, "audio/") {
		return "audio", true
	}
	if strings.HasPrefix(ctype, "video/") {
		return "video", true
	}
	if bytes.Contains(buf, []byte{0}) {
		return "data", true
	}
	return "", false
}

func isMachO(buf []byte) bool {
	mags := [][]byte{{0xfe, 0xed, 0xfa, 0xce}, {0xfe, 0xed, 0xfa, 0xcf}, {0xce, 0xfa, 0xed, 0xfe}, {0xcf, 0xfa, 0xed, 0xfe}, {0xca, 0xfe, 0xba, 0xbe}, {0xbe, 0xba, 0xfe, 0xca}}
	for _, mag := range mags {
		if len(buf) >= 4 && bytes.Equal(buf[:4], mag) {
			return true
		}
	}
	return false
}
