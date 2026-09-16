package main

import (
	"fmt"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/ext"
)

type blockSourceMacros struct{}

func (blockSourceMacros) LibraryName() string {
	return "probe.block.source.macros"
}

func (blockSourceMacros) CompileOptions() []cel.EnvOption {
	indexVariables := make([]cel.EnvOption, 16)
	for index := range indexVariables {
		indexVariables[index] = cel.Variable(fmt.Sprintf("@index%d", index), cel.DynType)
	}
	return append([]cel.EnvOption{cel.Macros(
		cel.ReceiverMacro("block", 2, expandBlock),
		cel.ReceiverMacro("index", 1, expandIndex),
		cel.ReceiverMacro("iterVar", 2, expandComprehensionVariable("cel.iterVar", "@it")),
		cel.ReceiverMacro("accuVar", 2, expandComprehensionVariable("cel.accuVar", "@ac")),
	)}, indexVariables...)
}

func (blockSourceMacros) ProgramOptions() []cel.ProgramOption {
	return nil
}

func expandBlock(factory cel.MacroExprFactory, target ast.Expr, arguments []ast.Expr) (ast.Expr, *cel.Error) {
	if !isCELNamespace(target) {
		return nil, nil
	}
	bindings := arguments[0]
	if bindings.Kind() != ast.ListKind {
		return bindings, factory.NewError(bindings.ID(), "cel.block requires the first arg to be a list literal")
	}
	return factory.NewCall("cel.@block", arguments...), nil
}

func expandIndex(factory cel.MacroExprFactory, target ast.Expr, arguments []ast.Expr) (ast.Expr, *cel.Error) {
	if !isCELNamespace(target) {
		return nil, nil
	}
	index := arguments[0]
	if !isNonNegativeInt(index) {
		return index, factory.NewError(index.ID(), "cel.index requires a single non-negative int constant arg")
	}
	return factory.NewIdent(fmt.Sprintf("@index%d", index.AsLiteral().(types.Int))), nil
}

func expandComprehensionVariable(functionName, prefix string) cel.MacroFactory {
	return func(factory cel.MacroExprFactory, target ast.Expr, arguments []ast.Expr) (ast.Expr, *cel.Error) {
		if !isCELNamespace(target) {
			return nil, nil
		}
		for _, argument := range arguments {
			if !isNonNegativeInt(argument) {
				return argument, factory.NewError(
					argument.ID(), fmt.Sprintf("%s requires two non-negative int constant args", functionName),
				)
			}
		}
		return factory.NewIdent(fmt.Sprintf(
			"%s:%d:%d", prefix, arguments[0].AsLiteral().(types.Int), arguments[1].AsLiteral().(types.Int),
		)), nil
	}
}

func isCELNamespace(target ast.Expr) bool {
	return target.Kind() == ast.IdentKind && target.AsIdent() == "cel"
}

func isNonNegativeInt(expression ast.Expr) bool {
	if expression.Kind() != ast.LiteralKind {
		return false
	}
	value := expression.AsLiteral()
	return value.Type() == cel.IntType && value.(types.Int) >= 0
}

func newEnvironment(successCalls, failureCalls *int) *cel.Env {
	environment, err := cel.NewEnv(
		ext.Bindings(ext.BindingsVersion(1)),
		cel.OptionalTypes(),
		cel.Lib(blockSourceMacros{}),
		cel.Function("success",
			cel.Overload("success", nil, cel.IntType,
				cel.FunctionBinding(func(...ref.Val) ref.Val {
					*successCalls++
					return types.IntOne
				}))),
		cel.Function("failure",
			cel.Overload("failure", nil, cel.BoolType,
				cel.FunctionBinding(func(...ref.Val) ref.Val {
					*failureCalls++
					return types.NewErr("probe failure")
				}))),
		cel.Function("suppress",
			cel.Overload("suppress", []*cel.Type{cel.BoolType, cel.BoolType}, cel.BoolType,
				cel.OverloadIsNonStrict(),
				cel.BinaryBinding(func(ref.Val, ref.Val) ref.Val { return types.False }))),
	)
	if err != nil {
		panic(err)
	}
	return environment
}

func compile(environment *cel.Env, source string) (cel.Program, error) {
	checked, issues := environment.Compile(source)
	if issues.Err() != nil {
		return nil, issues.Err()
	}
	return environment.Program(checked)
}

func evaluate(program cel.Program) string {
	value, _, err := program.Eval(cel.NoVars())
	if err != nil {
		return "error=" + normalizeError(err)
	}
	return fmt.Sprintf("value=%v", value)
}

func compileAndEvaluate(environment *cel.Env, source string) string {
	program, err := compile(environment, source)
	if err != nil {
		return "error=" + normalizeError(err)
	}
	return evaluate(program)
}

func normalizeError(err error) string {
	message := err.Error()
	for _, marker := range []string{"no such attribute", "undeclared reference", "expects two arguments", "expects a list constructor"} {
		if strings.Contains(message, marker) {
			return marker
		}
	}
	return strings.ReplaceAll(message, "\n", " | ")
}

func plan(environment *cel.Env, expression ast.Expr) string {
	program, err := environment.PlanProgram(ast.NewAST(expression, nil))
	if err != nil {
		return "error=" + normalizeError(err)
	}
	return evaluate(program)
}

func main() {
	var successCalls, failureCalls int
	environment := newEnvironment(&successCalls, &failureCalls)

	extOnly, err := cel.NewEnv(ext.Bindings(ext.BindingsVersion(1)))
	if err != nil {
		panic(err)
	}
	fmt.Printf("optional_slot_present %s\n", compileAndEvaluate(environment, "cel.block([?optional.of(1), 2], cel.index(0))"))
	fmt.Printf("optional_slot_absent %s\n", compileAndEvaluate(environment, "cel.block([?optional.none(), 2], cel.index(0))"))
	fmt.Printf("source_without_test_macros %s\n", compileAndEvaluate(extOnly, "cel.block([1], 1)"))
	fmt.Printf("ast_alias_as_source %s\n", compileAndEvaluate(extOnly, "cel.@block([1], @index0)"))

	parsed, issues := environment.Parse("cel.block([1, cel.index(0) + 1], cel.index(1))")
	if issues.Err() != nil {
		panic(issues.Err())
	}
	expanded, err := cel.AstToString(parsed)
	if err != nil {
		panic(err)
	}
	fmt.Printf("source_expansion %s\n", expanded)
	parsed, issues = environment.Parse("[cel.iterVar(1, 2), cel.accuVar(3, 4)]")
	if issues.Err() != nil {
		panic(issues.Err())
	}
	expanded, err = cel.AstToString(parsed)
	if err != nil {
		panic(err)
	}
	fmt.Printf("source_variable_expansion %s\n", expanded)
	fmt.Printf("source_block %s\n", compileAndEvaluate(environment, "cel.block([1, cel.index(0) + 1], cel.index(1))"))

	successProgram, err := compile(environment, "cel.block([success()], cel.index(0) + cel.index(0))")
	if err != nil {
		panic(err)
	}
	fmt.Printf("lazy_success_eval_1 %s calls=%d\n", evaluate(successProgram), successCalls)
	fmt.Printf("lazy_success_eval_2 %s calls=%d\n", evaluate(successProgram), successCalls)

	failureCalls = 0
	errorProgram, err := compile(environment, "cel.block([failure()], suppress(cel.index(0), cel.index(0)))")
	if err != nil {
		panic(err)
	}
	fmt.Printf("lazy_error_eval_1 %s calls=%d\n", evaluate(errorProgram), failureCalls)
	fmt.Printf("lazy_error_eval_2 %s calls=%d\n", evaluate(errorProgram), failureCalls)
	failureCalls = 0
	fmt.Printf("lazy_unused %s calls=%d\n", compileAndEvaluate(environment, "cel.block([failure()], true)"), failureCalls)

	fmt.Printf("forward_index %s\n", compileAndEvaluate(environment,
		"cel.block([cel.index(1) + 1, 5], cel.index(0))"))
	fmt.Printf("self_index %s\n", compileAndEvaluate(environment,
		"cel.block([cel.index(0)], cel.index(0))"))
	fmt.Printf("out_of_range_index %s\n", compileAndEvaluate(environment,
		"cel.block([1], cel.index(9))"))
	fmt.Printf("negative_source_index %s\n", compileAndEvaluate(environment,
		"cel.block([1], cel.index(-1))"))

	factory := ast.NewExprFactory()
	negativeAST := factory.NewCall(1, "cel.@block",
		factory.NewList(2, []ast.Expr{factory.NewIdent(3, "@index-1")}, nil),
		factory.NewIdent(4, "@index0"))
	fmt.Printf("negative_ast_index %s\n", plan(environment, negativeAST))
	badConstructor := factory.NewCall(1, "cel.@block", factory.NewLiteral(2, types.IntOne), factory.NewLiteral(3, types.True))
	fmt.Printf("bad_ast_constructor %s\n", plan(environment, badConstructor))
	badArity := factory.NewCall(1, "cel.@block",
		factory.NewList(2, nil, nil), factory.NewLiteral(3, types.True), factory.NewLiteral(4, types.False))
	fmt.Printf("bad_ast_arity %s\n", plan(environment, badArity))
	fmt.Printf("bad_source_constructor %s\n", compileAndEvaluate(environment, "cel.block(1, true)"))

	fmt.Printf("empty_block %s\n", compileAndEvaluate(environment, "cel.block([], 42)"))
	fmt.Printf("nested_block %s\n", compileAndEvaluate(environment,
		"cel.block([10, cel.block([20], cel.index(0) + 1)], cel.index(0) + cel.index(1))"))
	fmt.Printf("iteration_alias %s\n", compileAndEvaluate(environment,
		"[1, 2].map(cel.iterVar(0, 0), cel.iterVar(0, 0) + 1)"))
	fmt.Printf("nested_iteration_alias %s\n", compileAndEvaluate(environment,
		"[1, 2].map(cel.iterVar(0, 0), [10].map(cel.iterVar(1, 0), cel.iterVar(0, 0) + cel.iterVar(1, 0)))"))
	fmt.Printf("block_inside_iteration %s\n", compileAndEvaluate(environment,
		"[1, 2].map(cel.iterVar(0, 0), cel.block([cel.iterVar(0, 0) + 10], cel.index(0)))"))

	hoistedSource := "cel.block([cel.iterVar(0, 0) + 10], [1, 2].map(cel.iterVar(0, 0), cel.index(0)))"
	hoisted, issues := environment.Parse(hoistedSource)
	if issues.Err() != nil {
		panic(issues.Err())
	}
	_, checkIssues := environment.Check(hoisted)
	fmt.Printf("hoisted_loop_capture_check error=%s\n", normalizeError(checkIssues.Err()))
	hoistedProgram, err := environment.Program(hoisted)
	if err != nil {
		panic(err)
	}
	fmt.Printf("hoisted_loop_capture_unchecked %s\n", evaluate(hoistedProgram))
}
