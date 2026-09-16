package main

import (
	"fmt"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

func main() {
	environment, err := cel.NewEnv(ext.Strings(), cel.Variable("template", cel.StringType), cel.Variable("args", cel.ListType(cel.DynType)))
	if err != nil {
		panic(err)
	}
	for _, source := range []string{
		`'A😀e\u0301Z'.charAt(1)`, `'A😀e\u0301Z'.substring(1,4).reverse()`,
		`'abc'.charAt(3)`, `'abc'.charAt(4)`, `'abc'.indexOf('a',30)`, `'abc'.indexOf('',30)`,
		`'abc'.lastIndexOf('a',3)`, `'abc'.lastIndexOf('',30)`,
		`'😀ab'.replace('', '-', 3)`, `'😀ab'.split('',2)`, `''.split('')`,
		`'\u0085\u00a0x\u3000'.trim()`, `'\u200bx\ufeff'.trim()`,
		`strings.quote('a\x00b\n😀')`, `'%s'.format([b'\xff\xffA\xc0\xafB'])`,
		`'%s'.format([duration('1.500s')])`,
		`'%s'.format([duration('9223372036.854775807s')])`,
		`'%s'.format([duration('2405875930.906139466s')])`,
	} {
		parsed, issues := environment.Parse(source)
		if issues.Err() != nil {
			fmt.Printf("%s | parse=%v\n", source, issues.Err())
			continue
		}
		program, err := environment.Program(parsed)
		if err != nil {
			fmt.Printf("%s | program=%v\n", source, err)
			continue
		}
		result, _, err := program.Eval(map[string]any{})
		fmt.Printf("%s | value=%v | error=%v\n", source, result, err)
	}
	for _, row := range []struct {
		template string
		args     []any
	}{
		{"%.20f", []any{1.1}}, {"%.2f", []any{2.675}}, {"%.0f", []any{2.5}}, {"%.3f", []any{1.2345}},
		{"%.20e", []any{1.1}}, {"%d", []any{3.14}}, {"%s", []any{float64(1)}},
		{"%.3s", []any{"abcdef"}}, {"%.3d", []any{int64(42)}}, {"plain", []any{int64(1)}},
		{"%s", []any{"first", "unused"}},
	} {
		parsed, issues := environment.Compile("template.format(args)")
		if issues.Err() != nil {
			panic(issues.Err())
		}
		program, err := environment.Program(parsed)
		if err != nil {
			panic(err)
		}
		result, _, err := program.Eval(map[string]any{"template": row.template, "args": row.args})
		fmt.Printf("template=%q args=%v | value=%v | error=%v\n", row.template, row.args, result, err)
	}
}
