package main

import (
	"fmt"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/ext"
)

type probe struct {
	name       string
	source     string
	activation map[string]any
}

func main() {
	receiverCalls := 0
	keyCalls := 0
	environment, err := cel.NewEnv(
		ext.Lists(),
		cel.OptionalTypes(),
		cel.Variable("x", cel.StringType),
		cel.Variable("dyns", cel.ListType(cel.DynType)),
		cel.Variable("nested", cel.ListType(cel.ListType(cel.IntType))),
		cel.Function("probe.receiver", cel.Overload("probe_receiver", []*cel.Type{}, cel.ListType(cel.IntType),
			cel.FunctionBinding(func(...ref.Val) ref.Val {
				receiverCalls++
				return types.DefaultTypeAdapter.NativeToValue([]int64{3, 1, 2, 0})
			}))),
		cel.Function("probe.empty", cel.Overload("probe_empty", []*cel.Type{}, cel.ListType(cel.IntType),
			cel.FunctionBinding(func(...ref.Val) ref.Val {
				receiverCalls++
				return types.DefaultTypeAdapter.NativeToValue([]int64{})
			}))),
		cel.Function("probe.key", cel.Overload("probe_key", []*cel.Type{cel.IntType}, cel.IntType,
			cel.UnaryBinding(func(value ref.Val) ref.Val {
				keyCalls++
				return value
			}))),
		cel.Function("probe.failKey", cel.Overload("probe_fail_key", []*cel.Type{cel.IntType}, cel.IntType,
			cel.UnaryBinding(func(value ref.Val) ref.Val {
				keyCalls++
				if value == types.Int(2) {
					return types.NewErr("probe key error at %v", value)
				}
				return value
			}))),
	)
	if err != nil {
		panic(err)
	}

	probes := []probe{
		{"sort_mixed_numeric_values", `[3, 1u, 2.0].sort()`, nil},
		{"sortBy_mixed_numeric_keys", `[3, 1, 2].sortBy(x, x == 3 ? dyn(2) : x == 1 ? dyn(1u) : dyn(0.0))`, nil},
		{"sort_singleton_list_dynamic", `dyn([[1]]).sort()`, nil},
		{"sort_singleton_map_dynamic", `dyn([{'a': 1}]).sort()`, nil},
		{"sortBy_singleton_list_key_dynamic", `[1].sortBy(v, dyn([v]))`, nil},
		{"sort_nan_singleton", `[0.0 / 0.0].sort()`, nil},
		{"sort_nan_middle", `[2.0, 0.0 / 0.0, 1.0].sort()`, nil},
		{"sortBy_nan_key", `['b', 'a'].sortBy(v, v == 'b' ? 0.0 / 0.0 : 0.0)`, nil},
		{"sortBy_equal_key_groups_24", `lists.range(24).sortBy(v, v % 3)`, nil},
		{"sortBy_all_equal_24", `lists.range(24).sortBy(v, 0)`, nil},
		{"distinct_nested_numeric_aliases", `[[1], [1u], [1.0], [2]].distinct()`, nil},
		{"distinct_nested_nan", `[[0.0 / 0.0], [0.0 / 0.0]].distinct().size()`, nil},
		{"distinct_optional_none", `[optional.none(), optional.none()].distinct().size()`, nil},
		{"distinct_optional_numeric_aliases", `[optional.of(dyn(1)), optional.of(dyn(1u)), optional.of(dyn(1.0))].distinct().size()`, nil},
		{"distinct_optional_nan", `[optional.of(0.0 / 0.0), optional.of(0.0 / 0.0)].distinct().size()`, nil},
		{"sortBy_receiver_once", `probe.receiver().sortBy(v, v)`, nil},
		{"sortBy_key_once_per_element", `probe.receiver().sortBy(v, probe.key(v))`, nil},
		{"sortBy_empty_skips_key", `probe.empty().sortBy(v, probe.key(v))`, nil},
		{"sortBy_key_error", `probe.receiver().sortBy(v, probe.failKey(v))`, nil},
		{"sortBy_shadows_outer_x", `[3, 1, 2].sortBy(x, x)`, map[string]any{"x": "outer"}},
		{"sortBy_nested_shadowing", `[[3, 1], [2, 0]].sortBy(x, x.sortBy(x, x)[0])`, map[string]any{"x": "outer"}},
		{"sortBy_invalid_binding_literal", `[1].sortBy(1, 1)`, nil},
		{"sortBy_invalid_binding_select", `[1].sortBy(x.y, 1)`, nil},
		{"sortBy_invalid_receiver_scalar", `(1).sortBy(v, v)`, nil},
		{"sortBy_invalid_receiver_map", `{'x': 1}.sortBy(v, v)`, nil},
		{"sortBy_invalid_arity_one", `[1].sortBy(x)`, map[string]any{"x": "outer"}},
		{"sortBy_invalid_arity_three", `[1].sortBy(x, x, x)`, map[string]any{"x": "outer"}},
		{"check_list_dyn_empty", `dyns.sort()`, map[string]any{"dyns": []any{}}},
		{"check_list_dyn_mixed", `dyns.sort()`, map[string]any{"dyns": []any{int64(1), "x"}}},
		{"check_empty_literal", `[].sort()`, nil},
		{"check_mixed_literal", `[1, 'x'].sort()`, nil},
		{"check_list_list", `nested.sort()`, map[string]any{"nested": [][]int64{{1}}}},
		{"check_empty_unorderable_sortBy", `[].sortBy(v, [v])`, nil},
		{"check_empty_dynamic_unorderable_sortBy", `[].sortBy(v, dyn([v]))`, nil},
	}

	for _, probe := range probes {
		receiverCalls = 0
		keyCalls = 0
		ast, issues := environment.Compile(probe.source)
		if issues.Err() != nil {
			fmt.Printf("%s | source=%q | compile_error=%q | receiver_calls=%d | key_calls=%d\n",
				probe.name, probe.source, issues.Err(), receiverCalls, keyCalls)
			continue
		}
		program, err := environment.Program(ast)
		if err != nil {
			fmt.Printf("%s | source=%q | checked=%v | program_error=%q | receiver_calls=%d | key_calls=%d\n",
				probe.name, probe.source, ast.OutputType(), err, receiverCalls, keyCalls)
			continue
		}
		activation := probe.activation
		if activation == nil {
			activation = map[string]any{}
		}
		value, _, evalErr := program.Eval(activation)
		valueType := "<nil>"
		if value != nil {
			valueType = fmt.Sprint(value.Type())
		}
		fmt.Printf("%s | source=%q | checked=%v | value=%v | type=%s | eval_error=%q | receiver_calls=%d | key_calls=%d\n",
			probe.name, probe.source, ast.OutputType(), value, valueType, fmt.Sprint(evalErr), receiverCalls, keyCalls)
	}
	for _, container := range []string{"lists", "lists.child"} {
		env, err := cel.NewEnv(ext.Lists(), cel.Container(container))
		if err != nil {
			panic(err)
		}
		ast, issues := env.Compile("range(3)")
		if issues.Err() != nil {
			panic(issues.Err())
		}
		program, err := env.Program(ast)
		if err != nil {
			panic(err)
		}
		value, _, err := program.Eval(map[string]any{})
		fmt.Printf("container=%s | range(3)=%v | error=%v\n", container, value, err)
	}
}
