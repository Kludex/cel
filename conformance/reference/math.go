package main

import (
	"fmt"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

func main() {
	environment, err := cel.NewEnv(ext.Math())
	if err != nil {
		panic(err)
	}
	for _, source := range []string{
		"math.greatest(1, dyn(2.5))", "math.greatest(1u, 1, 1.0)",
		"math.least(0.0, -0.0)", "math.sign(-0.0)",
		"math.greatest(0.0 / 0.0)", "math.greatest(1.0, 0.0 / 0.0)",
		"math.least(dyn([]))", "math.greatest()", "math.least([])",
		"math.bitShiftRight(-1, 1)", "math.bitShiftLeft(-1, 64)",
		"math.bitShiftLeft(1, 63)", "math.bitShiftLeft(1u, -1)",
	} {
		ast, issues := environment.Compile(source)
		if issues.Err() != nil {
			fmt.Printf("%s: compile error: %s\n", source, issues.Err())
			continue
		}
		program, err := environment.Program(ast)
		if err != nil {
			panic(err)
		}
		value, _, err := program.Eval(map[string]interface{}{})
		fmt.Printf("%s: checked=%v value=%v type=%v error=%v\n", source, ast.OutputType(), value, value.Type(), err)
	}
}
