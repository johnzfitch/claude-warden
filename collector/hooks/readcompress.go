package hooks

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	readCompressJSONKeyRE         = regexp.MustCompile(`^[[:space:]]{0,4}"[^"]+":`)
	readCompressYAMLDocRE         = regexp.MustCompile(`^---`)
	readCompressYAMLKeyRE         = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_-]*:`)
	readCompressYAMLListRE        = regexp.MustCompile(`^- [a-zA-Z]`)
	readCompressINISectionRE      = regexp.MustCompile(`^\[`)
	readCompressINIKeyRE          = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_-]* *=`)
	readCompressXMLTagRE          = regexp.MustCompile(`^[[:space:]]*<[a-zA-Z][^>]*>`)
	readCompressPythonImportRE    = regexp.MustCompile(`^import [a-zA-Z]`)
	readCompressPythonFromRE      = regexp.MustCompile(`^from [a-zA-Z].* import `)
	readCompressClassRE           = regexp.MustCompile(`^class [a-zA-Z]`)
	readCompressPythonDefRE       = regexp.MustCompile(`^def [a-zA-Z]`)
	readCompressPythonAsyncDefRE  = regexp.MustCompile(`^async def [a-zA-Z]`)
	readCompressJSImportRE        = regexp.MustCompile(`^import .* from `)
	readCompressJSExportRE        = regexp.MustCompile(`^export (default |const |let |function |class |interface |type |enum )`)
	readCompressJSConstRE         = regexp.MustCompile(`^const [a-zA-Z].*=`)
	readCompressJSFunctionRE      = regexp.MustCompile(`^function [a-zA-Z]`)
	readCompressJSAsyncFunctionRE = regexp.MustCompile(`^async function [a-zA-Z]`)
	readCompressInterfaceRE       = regexp.MustCompile(`^interface [a-zA-Z]`)
	readCompressTypeRE            = regexp.MustCompile(`^type [a-zA-Z]`)
	readCompressRustUseRE         = regexp.MustCompile(`^use [a-zA-Z]`)
	readCompressRustPubRE         = regexp.MustCompile(`^pub (fn |struct |enum |trait |mod |type |use |const )`)
	readCompressRustFnRE          = regexp.MustCompile(`^fn [a-zA-Z]`)
	readCompressRustImplRE        = regexp.MustCompile(`^impl [a-zA-Z]`)
	readCompressRustStructRE      = regexp.MustCompile(`^struct [a-zA-Z]`)
	readCompressRustEnumRE        = regexp.MustCompile(`^enum [a-zA-Z]`)
	readCompressRustTraitRE       = regexp.MustCompile(`^trait [a-zA-Z]`)
	readCompressRustModRE         = regexp.MustCompile(`^mod [a-zA-Z]`)
	readCompressGoPackageRE       = regexp.MustCompile(`^package [a-zA-Z]`)
	readCompressGoImportRE        = regexp.MustCompile(`^import \(`)
	readCompressGoFuncRE          = regexp.MustCompile(`^func [a-zA-Z\(]`)
	readCompressGoTypeRE          = regexp.MustCompile(`^type [a-zA-Z]`)
	readCompressPHPTagRE          = regexp.MustCompile(`^<\?php`)
	readCompressPHPNamespaceRE    = regexp.MustCompile(`^namespace [a-zA-Z]`)
	readCompressPHPFunctionRE     = regexp.MustCompile(`^function [a-zA-Z]`)
	readCompressPHPTraitRE        = regexp.MustCompile(`^trait [a-zA-Z]`)
	readCompressMarkdownHeaderRE  = regexp.MustCompile(`^#{2,4} `)
	readCompressIndentedDefRE     = regexp.MustCompile(`^[[:space:]]+(pub fn |async fn |def |async def |public function |private function |protected function )`)
	readCompressIndentedMethodRE  = regexp.MustCompile(`^[[:space:]]+(public |private |protected )[a-zA-Z].*\(`)
	readCompressCodePatterns      = []*regexp.Regexp{
		readCompressPythonImportRE,
		readCompressPythonFromRE,
		readCompressClassRE,
		readCompressPythonDefRE,
		readCompressPythonAsyncDefRE,
		readCompressJSImportRE,
		readCompressJSExportRE,
		readCompressJSConstRE,
		readCompressJSFunctionRE,
		readCompressJSAsyncFunctionRE,
		readCompressClassRE,
		readCompressInterfaceRE,
		readCompressTypeRE,
		readCompressRustUseRE,
		readCompressRustPubRE,
		readCompressRustFnRE,
		readCompressRustImplRE,
		readCompressRustStructRE,
		readCompressRustEnumRE,
		readCompressRustTraitRE,
		readCompressRustModRE,
		readCompressGoPackageRE,
		readCompressGoImportRE,
		readCompressGoFuncRE,
		readCompressGoTypeRE,
		readCompressPHPTagRE,
		readCompressPHPNamespaceRE,
		readCompressClassRE,
		readCompressPHPFunctionRE,
		readCompressInterfaceRE,
		readCompressPHPTraitRE,
		readCompressMarkdownHeaderRE,
		readCompressIndentedDefRE,
		readCompressIndentedMethodRE,
	}
)

func init() {
	hookHandlers["read-compress"] = handleReadCompress
}

func handleReadCompress(input HookInput) ([]byte, int) {
	if input.ToolName != "Read" {
		return nil, 0
	}

	filePath := readCompressFilePath(input.ToolInput)
	content := extractToolResponseText(input)
	if content == "" {
		return nil, 0
	}

	content, stripped := readCompressStripReminders(content)
	exitMaybeStripped := func() ([]byte, int) {
		if stripped {
			return ModifyOutput(content), 0
		}
		return nil, 0
	}

	fileExt := strings.TrimPrefix(filepath.Ext(filePath), ".")
	switch fileExt {
	case "txt", "md", "markdown", "rst", "log", "csv", "tsv", "env", "conf", "gitignore", "dockerignore":
		return exitMaybeStripped()
	}

	lines := countLines(content)
	threshold := 500
	if readCompressIsSubagent(input.TranscriptPath) {
		threshold = 300
	}
	if lines <= threshold {
		return exitMaybeStripped()
	}

	if summary, summaryLines := readCompressConfigSummary(fileExt, content); summary != "" {
		if summaryLines >= lines {
			return exitMaybeStripped()
		}
		final := fmt.Sprintf("%s\n\n[Structure extracted: %d lines -> %d keys/sections]\n[Use Read with offset/limit for full content]", summary, lines, summaryLines)
		return ModifyOutput(final), 0
	}

	summary, summaryLines := readCompressCodeSummary(content)
	if summary == "" || summaryLines == 0 || summaryLines >= lines {
		return exitMaybeStripped()
	}

	final := fmt.Sprintf("%s\n\n[Structure extracted: %d lines -> %d signatures]\n[Use Read with offset/limit for implementation details]", summary, lines, summaryLines)
	return ModifyOutput(final), 0
}

func readCompressFilePath(raw json.RawMessage) string {
	var input ReadToolInput
	if err := json.Unmarshal(raw, &input); err == nil {
		return input.FilePath
	}
	return ""
}

func readCompressIsSubagent(transcriptPath string) bool {
	return strings.Contains(transcriptPath, "/subagents/")
}

func readCompressStripReminders(content string) (string, bool) {
	if !strings.Contains(content, "<system-reminder>") {
		return content, false
	}
	cleaned := stripSystemReminderBlocks(content)
	return cleaned, cleaned != content
}

func readCompressConfigSummary(fileExt, content string) (string, int) {
	switch fileExt {
	case "json":
		return readCompressSelectLines(content, 150, readCompressJSONKeyRE)
	case "yml", "yaml":
		return readCompressSelectLines(content, 150, readCompressYAMLDocRE, readCompressYAMLKeyRE, readCompressYAMLListRE)
	case "toml", "cfg", "ini":
		return readCompressSelectLines(content, 150, readCompressINISectionRE, readCompressINIKeyRE)
	case "xml", "svg", "html":
		return readCompressSelectLines(content, 100, readCompressXMLTagRE)
	default:
		return "", 0
	}
}

func readCompressCodeSummary(content string) (string, int) {
	return readCompressSelectLines(content, 200, readCompressCodePatterns...)
}

func readCompressSelectLines(content string, limit int, patterns ...*regexp.Regexp) (string, int) {
	lines := strings.Split(content, "\n")
	out := make([]string, 0, min(limit, len(lines)))
	for _, line := range lines {
		for _, pattern := range patterns {
			if pattern.MatchString(line) {
				out = append(out, line)
				break
			}
		}
		if len(out) >= limit {
			break
		}
	}
	if len(out) == 0 {
		return "", 0
	}
	return strings.Join(out, "\n"), len(out)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
