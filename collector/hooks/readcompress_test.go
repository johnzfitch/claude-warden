package hooks

import (
	"encoding/json"
	"strings"
	"testing"
)

type readCompressResult struct {
	ModifyOutput string `json:"modifyOutput"`
}

func TestReadCompressNonReadToolPassesThrough(t *testing.T) {
	out, code := handleReadCompress(HookInput{
		ToolName:     "Write",
		ToolInput:    marshalRaw(map[string]string{"file_path": "main.py"}),
		ToolResponse: HookToolResponse{Content: []ToolResponseBlock{{Text: numberedLines("x", 700)}}},
	})
	if code != 0 || len(out) != 0 {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestReadCompressEmptyContentPassesThrough(t *testing.T) {
	out, code := handleReadCompress(HookInput{
		ToolName:  "Read",
		ToolInput: marshalRaw(ReadToolInput{FilePath: "main.py"}),
	})
	if code != 0 || len(out) != 0 {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestReadCompressSkipsNonCodeExtensions(t *testing.T) {
	cases := []string{
		"notes.txt",
		"README.md",
		"guide.markdown",
		"doc.rst",
		"server.log",
		"data.csv",
		"data.tsv",
		".env",
		"app.conf",
		".gitignore",
		".dockerignore",
	}
	for _, path := range cases {
		t.Run(path, func(t *testing.T) {
			out, code := handleReadCompress(readCompressInput(path, numberedLines("skip", 700), ""))
			if code != 0 || len(out) != 0 {
				t.Fatalf("code=%d out=%q", code, out)
			}
		})
	}
}

func TestReadCompressStripsSystemReminderWithoutCompression(t *testing.T) {
	res, raw := runReadCompress(t, readCompressInput("main.py", "keep 1\n<system-reminder>\nnoise\n</system-reminder>\nkeep 2\n", ""))
	if len(raw) == 0 {
		t.Fatal("expected modifyOutput")
	}
	if res.ModifyOutput != "keep 1\nkeep 2" {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
}

func TestReadCompressMainThresholdAndPythonExtraction(t *testing.T) {
	out, code := handleReadCompress(readCompressInput("main.py", numberedLines("# comment", 499), ""))
	if code != 0 || len(out) != 0 {
		t.Fatalf("499-line main agent should pass through: code=%d out=%q", code, out)
	}

	out, code = handleReadCompress(readCompressInput("main.py", numberedLines("# comment", 500), ""))
	if code != 0 || len(out) != 0 {
		t.Fatalf("500-line main agent should pass through: code=%d out=%q", code, out)
	}

	content := strings.Join([]string{
		"import os",
		"from sys import path",
		"class Foo:",
		"    def bar(self):",
		"async def run():",
		numberedLines("# filler", 595),
	}, "\n")
	res, _ := runReadCompress(t, readCompressInput("main.py", content, ""))
	for _, want := range []string{"import os", "from sys import path", "class Foo:", "    def bar(self):", "async def run():", "[Structure extracted: 600 lines -> 5 signatures]"} {
		if !strings.Contains(res.ModifyOutput, want) {
			t.Fatalf("missing %q in %q", want, res.ModifyOutput)
		}
	}
}

func TestReadCompressSubagentThresholdsAndDetection(t *testing.T) {
	out, code := handleReadCompress(readCompressInput("worker.py", numberedLines("# comment", 299), "/work/subagents/agent-a.jsonl"))
	if code != 0 || len(out) != 0 {
		t.Fatalf("299-line subagent should pass through: code=%d out=%q", code, out)
	}

	out, code = handleReadCompress(readCompressInput("worker.py", numberedLines("# comment", 300), "/work/subagents/agent-a.jsonl"))
	if code != 0 || len(out) != 0 {
		t.Fatalf("300-line subagent should pass through: code=%d out=%q", code, out)
	}

	content := strings.Join([]string{
		"def alpha():",
		numberedLines("# filler", 300),
	}, "\n")
	res, _ := runReadCompress(t, readCompressInput("worker.py", content, "/work/subagents/agent-x.jsonl"))
	if !strings.Contains(res.ModifyOutput, "def alpha():") || !strings.Contains(res.ModifyOutput, "[Structure extracted: 301 lines -> 1 signatures]") {
		t.Fatalf("modifyOutput=%q", res.ModifyOutput)
	}
}

func TestReadCompressConfigExtraction(t *testing.T) {
	tests := []struct {
		name       string
		path       string
		transcript string
		content    string
		wants      []string
	}{
		{
			name:       "json",
			path:       "config.json",
			transcript: "/tmp/transcript.jsonl",
			content: strings.Join([]string{
				`"root": {`,
				`  "child": 1,`,
				`      "too_deep": true,`,
				numberedLines("      // filler", 597),
			}, "\n"),
			wants: []string{`"root": {`, `  "child": 1,`, `[Structure extracted: 600 lines -> 2 keys/sections]`},
		},
		{
			name: "yaml",
			path: "config.yaml",
			content: strings.Join([]string{
				"---",
				"root:",
				"- item",
				numberedLines("  child: value", 997),
			}, "\n"),
			wants: []string{"---", "root:", "- item", "keys/sections"},
		},
		{
			name: "ini",
			path: "config.ini",
			content: strings.Join([]string{
				"[core]",
				"root = true",
				numberedLines("  nested = true", 598),
			}, "\n"),
			wants: []string{"[core]", "root = true", "keys/sections"},
		},
		{
			name: "xml",
			path: "layout.xml",
			content: strings.Join([]string{
				`<root attr="1">`,
				`  <child name="x">`,
				numberedLines("text", 598),
			}, "\n"),
			wants: []string{`<root attr="1">`, `<child name="x">`, "keys/sections"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, _ := runReadCompress(t, readCompressInput(tt.path, tt.content, tt.transcript))
			for _, want := range tt.wants {
				if !strings.Contains(res.ModifyOutput, want) {
					t.Fatalf("missing %q in %q", want, res.ModifyOutput)
				}
			}
		})
	}
}

func TestReadCompressCodeExtractionPatterns(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		content string
		wants   []string
	}{
		{
			name: "typescript",
			path: "main.ts",
			content: strings.Join([]string{
				`import { x } from "y"`,
				"export class Foo {}",
				"const value = 1",
				"function run() {}",
				"async function wait() {}",
				"interface Shape {}",
				"type Name = string",
				numberedLines("// filler", 793),
			}, "\n"),
			wants: []string{"import { x } from \"y\"", "export class Foo {}", "interface Shape {}", "type Name = string"},
		},
		{
			name: "go",
			path: "main.go",
			content: strings.Join([]string{
				"package hooks",
				"import (",
				"func Run() {}",
				"type Thing struct{}",
				numberedLines("// filler", 596),
			}, "\n"),
			wants: []string{"package hooks", "import (", "func Run() {}", "type Thing struct{}"},
		},
		{
			name: "rust",
			path: "lib.rs",
			content: strings.Join([]string{
				"use std::fmt;",
				"pub fn run() {}",
				"fn helper() {}",
				"impl Thing {}",
				"struct Thing {}",
				"enum Kind {}",
				"trait Doer {}",
				"mod inner;",
				numberedLines("// filler", 592),
			}, "\n"),
			wants: []string{"use std::fmt;", "pub fn run() {}", "impl Thing {}", "trait Doer {}"},
		},
		{
			name: "php",
			path: "main.php",
			content: strings.Join([]string{
				"<?php",
				"namespace Demo;",
				"class Foo {}",
				"function run() {}",
				"interface Face {}",
				"trait Helper {}",
				numberedLines("// filler", 594),
			}, "\n"),
			wants: []string{"<?php", "namespace Demo;", "class Foo {}", "function run() {}", "interface Face {}", "trait Helper {}"},
		},
		{
			name: "unknown extension fallback",
			path: "script.custom",
			content: strings.Join([]string{
				"class Foo:",
				"def run():",
				numberedLines("# filler", 598),
			}, "\n"),
			wants: []string{"class Foo:", "def run():"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, _ := runReadCompress(t, readCompressInput(tt.path, tt.content, ""))
			for _, want := range tt.wants {
				if !strings.Contains(res.ModifyOutput, want) {
					t.Fatalf("missing %q in %q", want, res.ModifyOutput)
				}
			}
			if !strings.Contains(res.ModifyOutput, "signatures") {
				t.Fatalf("modifyOutput=%q", res.ModifyOutput)
			}
		})
	}
}

func TestReadCompressNoRecognizablePatternsPassesThrough(t *testing.T) {
	out, code := handleReadCompress(readCompressInput("main.py", numberedLines("# comment only", 700), ""))
	if code != 0 || len(out) != 0 {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestReadCompressLimitsCodeSummaryTo200Lines(t *testing.T) {
	content := numberedLinesWithPrefix("func Item", "() {}", 700)
	res, _ := runReadCompress(t, readCompressInput("many.go", content, ""))
	summary := strings.Split(res.ModifyOutput, "\n\n[Structure extracted:")[0]
	if got := countLines(summary); got != 200 {
		t.Fatalf("summary lines=%d want 200", got)
	}
}

func readCompressInput(path, content, transcript string) HookInput {
	input := HookInput{
		SessionID:      "sid",
		TranscriptPath: transcript,
		ToolName:       "Read",
		ToolInput:      marshalRaw(ReadToolInput{FilePath: path}),
	}
	input.ToolResponse.Content = []ToolResponseBlock{{Text: content}}
	return input
}

func runReadCompress(t *testing.T, input HookInput) (readCompressResult, []byte) {
	t.Helper()
	out, code := handleReadCompress(input)
	if code != 0 {
		t.Fatalf("code=%d want 0", code)
	}
	var res readCompressResult
	if len(out) > 0 {
		if err := json.Unmarshal(out, &res); err != nil {
			t.Fatalf("unmarshal %s: %v", out, err)
		}
	}
	return res, out
}

func numberedLines(prefix string, n int) string {
	lines := make([]string, n)
	for i := range n {
		lines[i] = prefix
	}
	return strings.Join(lines, "\n")
}

func numberedLinesWithPrefix(prefix, suffix string, n int) string {
	lines := make([]string, n)
	for i := range n {
		lines[i] = prefix + " " + string(rune('A'+(i%26))) + strings.Repeat("x", i/26) + suffix
	}
	return strings.Join(lines, "\n")
}
