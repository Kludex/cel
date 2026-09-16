package main

import (
	"encoding/json"
	"fmt"
	"os"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

func main() {
	env, err := cel.NewEnv(ext.TwoVarComprehensions())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	expressions := []string{
		"[].map(x)", "[].all()", "[].all(x, x, true)", "[].existsOne(x, true)", "has(1)", ".has({'x':1}.x)",
		"has(a.b.c)", "a.b.c", "[{'b': {'c': 4}}].all(a, a.b.c == 4 && .a.b.c == 3)",
		"dyn(9223372036854775807) < 9223372036854775808.0",
		"9007199254740993 == 9007199254740992.0", "int(-9223372036854775808.0)",
	}
	out := json.NewEncoder(os.Stdout)
	for _, source := range expressions {
		result := map[string]any{"expression": source}
		ast, issues := env.Parse(source)
		if issues.Err() != nil {
			result["phase"], result["error"] = "parse", issues.Err().Error()
		} else {
			program, err := env.Program(ast)
			if err != nil {
				result["phase"], result["error"] = "plan", err.Error()
			} else {
				value, _, err := program.Eval(map[string]any{"a.b.c": int64(3)})
				if err != nil {
					result["phase"], result["error"] = "evaluate", err.Error()
				} else {
					result["value"] = value.Value()
					result["type"] = value.Type().TypeName()
				}
			}
		}
		if err := out.Encode(result); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
