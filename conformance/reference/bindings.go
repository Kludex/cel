package main

import (
	"fmt"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/ext"
)

type calls struct {
	tick   int
	fail   int
	get    int
	custom int
}

type probe struct {
	name        string
	source      string
	activation  map[string]any
	evaluations int
	environment string
}

func main() {
	counts := &calls{}
	probes := []probe{
		{"unused_success", `cel.bind(v, probe.tick(), 42)`, nil, 2, "base"},
		{"unused_cel_error", `cel.bind(v, probe.tick() / 0, 42)`, nil, 2, "base"},
		{"unused_host_error", `cel.bind(v, probe.fail(), true)`, nil, 2, "base"},
		{"unused_get_key_error", `cel.bind(v, probe.get()['missing'], true)`, nil, 2, "base"},
		{"repeated_success", `cel.bind(v, probe.tick(), [v, v])`, nil, 2, "base"},
		{"repeated_cel_error_suppressed", `cel.bind(v, probe.tick() / 0, (v == 1 || true) && (v == 1 || true))`, nil, 2, "base"},
		{"repeated_key_error_suppressed", `cel.bind(v, probe.get()['missing'], (v == 1 || true) && (v == 1 || true))`, nil, 2, "base"},
		{"repeated_host_error_suppressed", `cel.bind(v, probe.fail(), (v == 1 || true) && (v == 1 || true))`, nil, 2, "base"},
		{"used_key_error", `cel.bind(v, probe.get()['missing'], v)`, nil, 1, "base"},
		{"used_host_error", `cel.bind(v, probe.fail(), v)`, nil, 1, "base"},
		{"get_receiver_success", `cel.bind(v, probe.get()['present'], [v, v])`, nil, 2, "base"},
		{"initializer_captures_outer", `cel.bind(x, x + 1, [x, .x])`, map[string]any{"x": int64(10)}, 2, "base"},
		{"nested_binding_shadow", `cel.bind(x, x + 1, cel.bind(x, x + 1, [x, .x]))`, map[string]any{"x": int64(10)}, 2, "base"},
		{"binding_visible_in_comprehension", `cel.bind(base, 10, [1, 2].map(item, cel.bind(sum, base + item, [base, item, sum])))`, nil, 1, "base"},
		{"comprehension_initializer_capture", `[1, 2].map(x, cel.bind(x, x + 1, [x, .x]))`, map[string]any{"x": int64(10)}, 1, "base"},
		{"nested_comprehension_scope", `[1, 2].map(x, [3].map(y, cel.bind(z, x + y, [x, y, z])))`, map[string]any{"x": int64(10)}, 1, "base"},
		{"wrong_arity_two", `cel.bind(x, 1)`, map[string]any{"x": int64(10)}, 1, "base"},
		{"wrong_arity_four", `cel.bind(x, 1, x, x)`, map[string]any{"x": int64(10)}, 1, "base"},
		{"invalid_identifier_literal", `cel.bind(1, 2, 3)`, nil, 1, "base"},
		{"invalid_identifier_select", `cel.bind(x.y, 1, x.y)`, nil, 1, "base"},
		{"invalid_identifier_absolute", `cel.bind(.x, 1, .x)`, map[string]any{"x": int64(10)}, 1, "base"},
		{"absolute_cel_namespace", `.cel.bind(x, 1, x)`, map[string]any{"x": int64(10)}, 1, "base"},
		{"other_namespace", `other.bind(x, 1, x)`, map[string]any{"x": int64(10)}, 1, "base"},
		{"variable_named_cel", `cel.bind(v, probe.tick(), [v, v])`, map[string]any{"cel": map[string]any{"bind": int64(99)}}, 1, "cel_variable"},
		{"custom_family_macro_precedence", `cel.bind(v, 7, v)`, nil, 1, "custom_bind"},
		{"custom_family_invalid_identifier", `cel.bind(1, 2, 3)`, nil, 1, "custom_bind"},
		{"custom_family_absolute_call", `.cel.bind(1, 2, 3)`, nil, 2, "custom_bind"},
	}

	environments := map[string]*cel.Env{}
	for _, mode := range []string{"base", "cel_variable", "custom_bind"} {
		environment, err := newEnvironment(counts, mode)
		if err != nil {
			panic(err)
		}
		environments[mode] = environment
	}

	for _, p := range probes {
		*counts = calls{}
		environment := environments[p.environment]
		parsed, issues := environment.Parse(p.source)
		if issues.Err() != nil {
			fmt.Printf("%s | source=%q | parse_error=%q | calls=%s\n", p.name, p.source, issues.Err(), counts)
			continue
		}
		checked, issues := environment.Check(parsed)
		if issues.Err() != nil {
			fmt.Printf("%s | source=%q | check_error=%q | calls=%s\n", p.name, p.source, issues.Err(), counts)
			continue
		}
		program, err := environment.Program(checked)
		if err != nil {
			fmt.Printf("%s | source=%q | checked=%v | program_error=%q | calls=%s\n", p.name, p.source, checked.OutputType(), err, counts)
			continue
		}
		activation := p.activation
		if activation == nil {
			activation = map[string]any{}
		}
		var result strings.Builder
		fmt.Fprintf(&result, "%s | source=%q | checked=%v", p.name, p.source, checked.OutputType())
		for i := 1; i <= p.evaluations; i++ {
			before := *counts
			value, _, evalErr := program.Eval(activation)
			valueType := "<nil>"
			if value != nil {
				valueType = fmt.Sprint(value.Type())
			}
			delta := calls{
				tick:   counts.tick - before.tick,
				fail:   counts.fail - before.fail,
				get:    counts.get - before.get,
				custom: counts.custom - before.custom,
			}
			fmt.Fprintf(&result, " | eval%d_value=%v | eval%d_type=%s | eval%d_error=%q | eval%d_calls=%s", i, value, i, valueType, i, fmt.Sprint(evalErr), i, &delta)
		}
		fmt.Fprintf(&result, " | total_calls=%s", counts)
		fmt.Println(result.String())
	}
}

func newEnvironment(counts *calls, mode string) (*cel.Env, error) {
	options := []cel.EnvOption{
		ext.Bindings(),
		cel.Variable("x", cel.IntType),
		cel.Function("probe.tick", cel.Overload("probe_tick", []*cel.Type{}, cel.IntType,
			cel.FunctionBinding(func(...ref.Val) ref.Val {
				counts.tick++
				return types.Int(counts.tick)
			}))),
		cel.Function("probe.fail", cel.Overload("probe_fail", []*cel.Type{}, cel.IntType,
			cel.FunctionBinding(func(...ref.Val) ref.Val {
				counts.fail++
				return types.NewErr("probe host error")
			}))),
		cel.Function("probe.get", cel.Overload("probe_get", []*cel.Type{}, cel.MapType(cel.StringType, cel.IntType),
			cel.FunctionBinding(func(...ref.Val) ref.Val {
				counts.get++
				return types.DefaultTypeAdapter.NativeToValue(map[string]int64{"present": 7})
			}))),
	}
	if mode == "cel_variable" {
		options = append(options, cel.Variable("cel", cel.MapType(cel.StringType, cel.DynType)))
	}
	if mode == "custom_bind" {
		options = append(options, cel.Function("cel.bind", cel.Overload("custom_cel_bind", []*cel.Type{cel.IntType, cel.IntType, cel.IntType}, cel.IntType,
			cel.FunctionBinding(func(values ...ref.Val) ref.Val {
				counts.custom++
				return types.Int(100 + values[0].(types.Int) + values[1].(types.Int) + values[2].(types.Int))
			}))))
	}
	return cel.NewEnv(options...)
}

func (c *calls) String() string {
	return fmt.Sprintf("tick:%d,fail:%d,get:%d,custom:%d", c.tick, c.fail, c.get, c.custom)
}
