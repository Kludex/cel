package main

import (
	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"fmt"
)

func main() {
	env, err := cel.NewEnv(cel.Function("same", cel.Overload("same_T_T", []*cel.Type{cel.TypeParamType("T"), cel.TypeParamType("T")}, cel.BoolType, cel.BinaryBinding(func(a, b ref.Val) ref.Val { return types.True }))))
	if err != nil {
		panic(err)
	}
	for _, source := range []string{"same(dyn(1), 'x')", "same(1, 'x')", "same(dyn(1), dyn('x'))"} {
		ast, issues := env.Compile(source)
		if issues.Err() != nil {
			fmt.Printf("%s: check error %s\n", source, issues.Err())
			continue
		}
		p, err := env.Program(ast)
		if err != nil {
			panic(err)
		}
		out, _, err := p.Eval(map[string]interface{}{})
		fmt.Printf("%s: result=%v error=%v\n", source, out, err)
	}
}
