package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

type probe struct {
	group  string
	name   string
	source string
}

func main() {
	environment, err := cel.NewEnv(ext.Network(), ext.Bindings(), ext.Lists(),
		cel.Variable("request", cel.DynType), cel.Variable("routes", cel.DynType))
	if err != nil {
		panic(err)
	}

	fmt.Printf("reference=cel-go@16c2ebb13679d18704cee890f3fdc861fe2ca7b1 | go=%s\n", runtime.Version())

	probes := []probe{
		{"classification", "ipv4",
			`[ip('0.0.0.0').isUnspecified(), ip('127.42.0.1').isLoopback(), ` +
				`ip('192.168.0.1').isGlobalUnicast(), ip('224.0.0.1').isLinkLocalMulticast(), ` +
				`ip('169.254.1.2').isLinkLocalUnicast()]`},
		{"classification", "ipv6",
			`[ip('::').isUnspecified(), ip('::1').isLoopback(), ip('2001:db8::1').isGlobalUnicast(), ` +
				`ip('ff02::1').isLinkLocalMulticast(), ip('fe80::1').isLinkLocalUnicast()]`},
		{"classification", "false_cases",
			`[ip('255.255.255.255').isGlobalUnicast(), ip('224.0.1.1').isLinkLocalMulticast(), ` +
				`ip('192.168.0.1').isLinkLocalUnicast(), ip('ff00::1').isGlobalUnicast(), ` +
				`ip('fd00::1').isLinkLocalMulticast(), ip('fd80::1').isLinkLocalUnicast()]`},
		{"canonical", "ipv6", `string(ip('2001:0DB8:0:0:1:0:0:1'))`},
		{"canonical", "embedded_ipv4", `string(ip('2001:db8::192.0.2.1'))`},
		{"malformed", "mapped_dotted", `ip('::ffff:192.0.2.1')`},
		{"malformed", "mapped_hex", `ip('::ffff:c000:201')`},
		{"malformed", "ipv4_leading_zero", `ip('192.168.001.1')`},
		{"malformed", "cidr_ipv4_leading_zero", `cidr('192.168.001.1/24')`},
		{"cidr", "host_bits_preserved", `string(cidr('192.168.0.129/24'))`},
		{"cidr", "masked", `string(cidr('192.168.0.129/24').masked())`},
		{"cidr", "containment",
			`[cidr('192.168.0.129/24').containsIP(ip('192.168.0.1')), ` +
				`cidr('192.168.0.129/24').containsCIDR(cidr('192.168.0.250/32')), ` +
				`cidr('192.168.0.129/24').containsCIDR(cidr('192.168.0.0/23')), ` +
				`cidr('2001:db8::1/32').containsCIDR(cidr('2001:db8:ffff::1/48'))]`},
		{"malformed", "empty_prefix", `cidr('192.168.0.1/')`},
		{"malformed", "leading_zero_prefix", `cidr('192.168.0.1/024')`},
		{"malformed", "ipv4_prefix_too_large", `cidr('192.168.0.1/33')`},
		{"malformed", "ipv6_prefix_too_large", `cidr('2001:db8::1/129')`},
		{"corpus_contradiction", "compile_not_evaluate_error", `isIP(cidr('192.168.0.0/24'))`},
		{"corpus_contradiction", "mapped_hex_equals_ipv4", `ip('::ffff:c0a8:1') == ip('192.168.0.1')`},
		{"corpus_contradiction", "mapped_hex_not_equals_ipv4", `ip('::ffff:c0a8:1') == ip('192.168.10.1')`},
	}

	for _, probe := range probes {
		ast, issues := environment.Compile(probe.source)
		if issues.Err() != nil {
			fmt.Printf("%s/%s | source=%q | compile_error=%q\n", probe.group, probe.name, probe.source, issues.Err())
		}
		ast, issues = environment.Parse(probe.source)
		if issues.Err() != nil {
			panic(issues.Err())
		}
		program, err := environment.Program(ast)
		if err != nil {
			fmt.Printf("%s/%s | source=%q | program_error=%q\n", probe.group, probe.name, probe.source, err)
			continue
		}
		result, _, err := program.Eval(map[string]any{})
		fmt.Printf("%s/%s | source=%q | value=%v | error=%v\n", probe.group, probe.name, probe.source, result, err)
	}

	if len(os.Args) == 2 {
		data, err := os.ReadFile(os.Args[1])
		if err != nil {
			panic(err)
		}
		var workloads []struct {
			Name       string
			Expression string
			Cases      []struct {
				Name     string
				Bindings map[string]any
				Expected any
			}
		}
		if err := json.Unmarshal(data, &workloads); err != nil {
			panic(err)
		}
		for _, workload := range workloads {
			if workload.Name != "network_gateway_authorization" {
				continue
			}
			ast, issues := environment.Compile(workload.Expression)
			if issues.Err() != nil {
				panic(issues.Err())
			}
			program, err := environment.Program(ast)
			if err != nil {
				panic(err)
			}
			for _, test := range workload.Cases {
				result, _, err := program.Eval(test.Bindings)
				if err != nil || result.Value() != test.Expected {
					panic(fmt.Sprintf("%s: value=%v error=%v expected=%v", test.Name, result, err, test.Expected))
				}
				fmt.Printf("application/%s | value=%v\n", test.Name, result)
			}
		}
	}
}
