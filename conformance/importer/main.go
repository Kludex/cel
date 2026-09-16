package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	_ "cel.dev/expr/conformance/proto2"
	_ "cel.dev/expr/conformance/proto3"
	conformance "cel.dev/expr/conformance/test"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/encoding/prototext"
)

const (
	upstreamCommit = "ba58ae5007845f3a1279b488cdeb79645ce958bb"
	upstreamModule = "cel.dev/expr@v0.25.3"
	upstreamURL    = "https://github.com/google/cel-spec"
)

type fileManifest struct {
	Name         string `json:"name"`
	Kind         string `json:"kind"`
	Source       string `json:"source"`
	Output       string `json:"output"`
	SourceSHA256 string `json:"sourceSha256"`
	OutputSHA256 string `json:"outputSha256"`
	Tests        int    `json:"tests"`
}

type sourceManifest struct {
	Repository string `json:"repository"`
	Commit     string `json:"commit"`
	Module     string `json:"module"`
	Path       string `json:"path"`
	License    string `json:"license"`
}

type summaryManifest struct {
	Files          int `json:"files"`
	CoreFiles      int `json:"coreFiles"`
	ExtensionFiles int `json:"extensionFiles"`
	Tests          int `json:"tests"`
	CoreTests      int `json:"coreTests"`
	ExtensionTests int `json:"extensionTests"`
}

type manifest struct {
	SchemaVersion int             `json:"schemaVersion"`
	Source        sourceManifest  `json:"source"`
	Summary       summaryManifest `json:"summary"`
	Files         []fileManifest  `json:"files"`
}

func main() {
	source := flag.String("source", "/tmp/cel-spec-reference", "path to the pinned cel-spec clone")
	output := flag.String("output", "../testdata", "directory for imported JSON")
	flag.Parse()

	if err := run(*source, *output); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(source string, output string) error {
	head, err := exec.Command("git", "-C", source, "rev-parse", "HEAD").Output()
	if err != nil {
		return fmt.Errorf("read upstream revision: %w", err)
	}
	if strings.TrimSpace(string(head)) != upstreamCommit {
		return fmt.Errorf("upstream HEAD must be %s", upstreamCommit)
	}

	pattern := filepath.Join(source, "tests", "simple", "testdata", "*.textproto")
	paths, err := filepath.Glob(pattern)
	if err != nil {
		return fmt.Errorf("find source files: %w", err)
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		return fmt.Errorf("no source files matched %s", pattern)
	}

	if err := os.MkdirAll(output, 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	old, err := filepath.Glob(filepath.Join(output, "*.json"))
	if err != nil {
		return fmt.Errorf("find old output files: %w", err)
	}
	for _, path := range old {
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("remove %s: %w", path, err)
		}
	}

	result := manifest{
		SchemaVersion: 1,
		Source: sourceManifest{
			Repository: upstreamURL,
			Commit:     upstreamCommit,
			Module:     upstreamModule,
			Path:       "tests/simple/testdata/*.textproto",
			License:    "Apache-2.0",
		},
	}
	marshal := protojson.MarshalOptions{Indent: "  "}
	for _, path := range paths {
		sourceData, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		file := &conformance.SimpleTestFile{}
		if err := prototext.Unmarshal(sourceData, file); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		outputData, err := marshal.Marshal(file)
		if err != nil {
			return fmt.Errorf("marshal %s: %w", path, err)
		}
		outputData = append(outputData, '\n')
		name := strings.TrimSuffix(filepath.Base(path), ".textproto")
		outputName := name + ".json"
		if err := os.WriteFile(filepath.Join(output, outputName), outputData, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", outputName, err)
		}
		tests := 0
		for _, section := range file.GetSection() {
			tests += len(section.GetTest())
		}
		kind := "core"
		if strings.HasSuffix(name, "_ext") {
			kind = "extension"
			result.Summary.ExtensionFiles++
			result.Summary.ExtensionTests += tests
		} else {
			result.Summary.CoreFiles++
			result.Summary.CoreTests += tests
		}
		result.Files = append(result.Files, fileManifest{
			Name:         name,
			Kind:         kind,
			Source:       "tests/simple/testdata/" + filepath.Base(path),
			Output:       outputName,
			SourceSHA256: digest(sourceData),
			OutputSHA256: digest(outputData),
			Tests:        tests,
		})
		result.Summary.Tests += tests
	}
	result.Summary.Files = len(result.Files)
	manifestData, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}
	manifestData = append(manifestData, '\n')
	if err := os.WriteFile(filepath.Join(output, "manifest.json"), manifestData, 0o644); err != nil {
		return fmt.Errorf("write manifest: %w", err)
	}
	return nil
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
