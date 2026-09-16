package main

import (
	"encoding/hex"
	"fmt"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/ext"
	proto2pb "cel.dev/cel-go/test/proto2pb"
	"google.golang.org/protobuf/proto"
)

const extensionName = "google.expr.proto2.test.int32_ext"

type probeCase struct {
	name   string
	source string
	vars   map[string]any
}

func main() {
	fmt.Println("cel-go=16c2ebb13679d18704cee890f3fdc861fe2ca7b1")
	probeProtos()
	probeBase64()
}

func probeProtos() {
	present := &proto2pb.ExampleType{}
	proto.SetExtension(present, proto2pb.E_Int32Ext, int32(42))
	proto.SetExtension(present, proto2pb.E_ExtendedExampleType_ExtendedExamples, []string{"one", "two"})
	explicitZero := &proto2pb.ExampleType{}
	proto.SetExtension(explicitZero, proto2pb.E_Int32Ext, int32(0))
	emptyRepeated := &proto2pb.ExampleType{}
	proto.SetExtension(emptyRepeated, proto2pb.E_ExtendedExampleType_ExtendedExamples, []string{})

	environment, err := cel.NewEnv(
		cel.Container("google.expr.proto2.test"),
		cel.Types(&proto2pb.ExampleType{}, &proto2pb.ExternalMessageType{}),
		cel.Variable("msg", cel.ObjectType("google.expr.proto2.test.ExampleType")),
		cel.Variable("absent", cel.ObjectType("google.expr.proto2.test.ExampleType")),
		cel.Variable("explicitZero", cel.ObjectType("google.expr.proto2.test.ExampleType")),
		cel.Variable("emptyRepeated", cel.ObjectType("google.expr.proto2.test.ExampleType")),
		cel.Variable("wrong", cel.ObjectType("google.expr.proto2.test.ExternalMessageType")),
		cel.Variable("extensionMap", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("proto", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable(extensionName, cel.StringType),
		cel.EnableIdentifierEscapeSyntax(),
		cel.Function("getExt", cel.MemberOverload("probe_get_ext", []*cel.Type{cel.DynType, cel.DynType, cel.DynType}, cel.StringType,
			cel.FunctionBinding(func(args ...ref.Val) ref.Val { return types.String("custom-getExt") }))),
		cel.Function("hasExt", cel.MemberOverload("probe_has_ext", []*cel.Type{cel.DynType, cel.DynType, cel.DynType}, cel.BoolType,
			cel.FunctionBinding(func(args ...ref.Val) ref.Val { return types.False }))),
		ext.Protos(),
	)
	if err != nil {
		panic(err)
	}
	vars := map[string]any{
		"msg":           present,
		"absent":        &proto2pb.ExampleType{},
		"explicitZero":  explicitZero,
		"emptyRepeated": emptyRepeated,
		"wrong":         &proto2pb.ExternalMessageType{},
		"extensionMap":  map[string]any{extensionName: int64(73)},
		"proto":         map[string]any{"value": int64(1)},
		extensionName:   "shadow-extension-variable",
	}

	fmt.Println("[protos]")
	for _, probe := range []probeCase{
		{"present_has", "proto.hasExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"present_get", "proto.getExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"absent_has", "proto.hasExt(absent, google.expr.proto2.test.int32_ext)", vars},
		{"absent_default_get", "proto.getExt(absent, google.expr.proto2.test.int32_ext)", vars},
		{"explicit_default_has", "proto.hasExt(explicitZero, google.expr.proto2.test.int32_ext)", vars},
		{"explicit_default_get", "proto.getExt(explicitZero, google.expr.proto2.test.int32_ext)", vars},
		{"repeated_present_has", "proto.hasExt(msg, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"repeated_present_get", "proto.getExt(msg, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"repeated_absent_has", "proto.hasExt(absent, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"repeated_absent_get", "proto.getExt(absent, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"repeated_explicit_empty_has", "proto.hasExt(emptyRepeated, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"repeated_explicit_empty_get", "proto.getExt(emptyRepeated, google.expr.proto2.test.ExtendedExampleType.extended_examples)", vars},
		{"wrong_message_has", "proto.hasExt(wrong, google.expr.proto2.test.int32_ext)", vars},
		{"wrong_message_get", "proto.getExt(wrong, google.expr.proto2.test.int32_ext)", vars},
		{"map_present_has", "proto.hasExt(extensionMap, google.expr.proto2.test.int32_ext)", vars},
		{"map_present_get", "proto.getExt(extensionMap, google.expr.proto2.test.int32_ext)", vars},
		{"map_absent_has", "proto.hasExt({}, google.expr.proto2.test.int32_ext)", vars},
		{"map_absent_get", "proto.getExt({}, google.expr.proto2.test.int32_ext)", vars},
		{"name_fully_qualified", "proto.getExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"name_relative_qualified", "proto.getExt(msg, proto2.test.int32_ext)", vars},
		{"name_simple", "proto.getExt(msg, int32_ext)", vars},
		{"name_string", "proto.getExt(msg, 'google.expr.proto2.test.int32_ext')", vars},
		{"name_quoted_whole", "proto.getExt(msg, `google.expr.proto2.test.int32_ext`)", vars},
		{"name_quoted_component", "proto.getExt(msg, google.expr.proto2.test.`int32_ext`)", vars},
		{"name_absolute", "proto.getExt(msg, .google.expr.proto2.test.int32_ext)", vars},
		{"extension_path_variable", "google.expr.proto2.test.int32_ext", vars},
		{"extension_path_ignored_by_macro", "proto.getExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"proto_variable_macro_get", "proto.getExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"proto_variable_macro_has", "proto.hasExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"macro_precedes_custom_get", "proto.getExt(msg, 'literal')", vars},
		{"macro_precedes_custom_has", "proto.hasExt(msg, 'literal')", vars},
		{"nonmatching_target_custom_get", "dyn(proto).getExt(msg, google.expr.proto2.test.int32_ext)", vars},
		{"nonmatching_target_custom_has", "dyn(proto).hasExt(msg, google.expr.proto2.test.int32_ext)", vars},
	} {
		run(environment, probe)
	}

	versionZero, err := cel.NewEnv(
		cel.Container("google.expr.proto2.test"),
		cel.Types(&proto2pb.ExampleType{}, &proto2pb.ExternalMessageType{}),
		cel.Variable("msg", cel.ObjectType("google.expr.proto2.test.ExampleType")),
		ext.Protos(ext.ProtosVersion(0)),
	)
	if err != nil {
		panic(err)
	}
	run(versionZero, probeCase{"protos_version_0", "proto.getExt(msg, google.expr.proto2.test.int32_ext)", vars})
}

func probeBase64() {
	defaultEnv := mustEnv(ext.Encoders())
	fmt.Println("[base64]")
	for _, probe := range []probeCase{
		{"std_encode_padded", "base64.encode(b'f')", nil},
		{"std_decode_padded_1", "base64.decode('Zg==')", nil},
		{"std_decode_unpadded_1", "base64.decode('Zg')", nil},
		{"std_decode_padded_2", "base64.decode('Zm8=')", nil},
		{"std_decode_unpadded_2", "base64.decode('Zm8')", nil},
		{"std_decode_cr", "base64.decode('Zg==\\r')", nil},
		{"std_decode_lf", "base64.decode('Zg==\\n')", nil},
		{"std_decode_crlf_interior", "base64.decode('Z\\r\\ng==')", nil},
		{"std_decode_space", "base64.decode('Z g==')", nil},
		{"std_decode_tab", "base64.decode('Z\\tg==')", nil},
		{"std_nonzero_pad_bits_1_padded", "base64.decode('Zh==')", nil},
		{"std_nonzero_pad_bits_2_padded", "base64.decode('Zm9=')", nil},
		{"std_nonzero_pad_bits_1_raw", "base64.decode('Zh')", nil},
		{"std_nonzero_pad_bits_2_raw", "base64.decode('Zm9')", nil},
		{"std_excess_padding", "base64.decode('Zg===')", nil},
		{"std_interior_padding", "base64.decode('Z=g=')", nil},
		{"std_leading_padding", "base64.decode('=Zg==')", nil},
		{"std_incomplete_padding", "base64.decode('Zg=')", nil},
		{"url_encode_padded", "base64.encodeUrl(b'\\xfb')", nil},
		{"url_encode_alphabet", "base64.encodeUrl(b'\\xff\\xff\\xff')", nil},
		{"url_decode_padded", "base64.decodeUrl('-w==')", nil},
		{"url_decode_unpadded", "base64.decodeUrl('-w')", nil},
		{"url_decode_nonzero_pad_bits", "base64.decodeUrl('-x==')", nil},
		{"url_reject_standard_alphabet", "base64.decodeUrl('+w==')", nil},
		{"std_reject_url_alphabet", "base64.decode('-w==')", nil},
	} {
		run(defaultEnv, probe)
	}

	fmt.Println("[encoder_versions]")
	run(defaultEnv, probeCase{"encoders_default_url", "base64.encodeUrl(b'f')", nil})
	run(mustEnv(ext.Encoders(ext.EncodersVersion(0))), probeCase{"encoders_v0_standard", "base64.encode(b'f')", nil})
	run(mustEnv(ext.Encoders(ext.EncodersVersion(0))), probeCase{"encoders_v0_url", "base64.encodeUrl(b'f')", nil})
	run(mustEnv(ext.Encoders(ext.EncodersVersion(1))), probeCase{"encoders_v1_url", "base64.encodeUrl(b'f')", nil})
	run(mustEnv(ext.Encoders(ext.EncodersVersion(2))), probeCase{"encoders_v2_url", "base64.encodeUrl(b'f')", nil})
}

func mustEnv(options ...cel.EnvOption) *cel.Env {
	environment, err := cel.NewEnv(options...)
	if err != nil {
		panic(err)
	}
	return environment
}

func run(environment *cel.Env, probe probeCase) {
	parsed, issues := environment.Parse(probe.source)
	if issues.Err() != nil {
		fmt.Printf("%s | source=%q | parse_error=%q\n", probe.name, probe.source, oneLine(issues.Err()))
		return
	}
	checked, issues := environment.Check(parsed)
	if issues.Err() != nil {
		value, valueType, evalErr := evaluate(environment, parsed, probe.vars)
		fmt.Printf("%s | source=%q | check_error=%q | unchecked_value=%s | unchecked_type=%s | unchecked_error=%q\n",
			probe.name, probe.source, oneLine(issues.Err()), value, valueType, oneLine(evalErr))
		return
	}
	value, valueType, evalErr := evaluate(environment, checked, probe.vars)
	fmt.Printf("%s | source=%q | checked=%s | value=%s | type=%s | eval_error=%q\n",
		probe.name, probe.source, checked.OutputType(), value, valueType, oneLine(evalErr))
}

func evaluate(environment *cel.Env, ast *cel.Ast, vars map[string]any) (string, string, error) {
	program, err := environment.Program(ast)
	if err != nil {
		return "<none>", "<none>", err
	}
	if vars == nil {
		vars = map[string]any{}
	}
	value, _, err := program.Eval(vars)
	if value == nil {
		return "<nil>", "<nil>", err
	}
	return formatValue(value), fmt.Sprint(value.Type()), err
}

func formatValue(value ref.Val) string {
	switch value := value.(type) {
	case types.Bytes:
		return "0x" + hex.EncodeToString([]byte(value))
	case types.String:
		return fmt.Sprintf("%q", string(value))
	default:
		return fmt.Sprintf("%v", value)
	}
}

func oneLine(err error) string {
	if err == nil {
		return "<nil>"
	}
	return strings.ReplaceAll(err.Error(), "\n", "\\n")
}
