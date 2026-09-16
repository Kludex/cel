// Evaluate generated cross-type numeric comparisons with the pinned CEL-Go runtime.
// Usage: go run numeric.go expressions.json results.json
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"cel.dev/cel-go/cel"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: numeric.go expressions.json results.json")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var exprs []string
	if err := json.Unmarshal(data, &exprs); err != nil {
		panic(err)
	}
	env, err := cel.NewEnv()
	if err != nil {
		panic(err)
	}
	out := map[string]string{}
	for _, src := range exprs {
		ast, iss := env.Parse(src)
		if iss.Err() != nil {
			out[src] = "parse:" + iss.Err().Error()
			continue
		}
		prg, err := env.Program(ast)
		if err != nil {
			panic(err)
		}
		v, _, err := prg.Eval(map[string]any{})
		if err != nil {
			out[src] = "err:" + err.Error()
		} else {
			out[src] = fmt.Sprintf("%v", v)
		}
	}
	encoded, _ := json.Marshal(out)
	if err := os.WriteFile(os.Args[2], encoded, 0o644); err != nil {
		panic(err)
	}
}
