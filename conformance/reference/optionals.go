package main

import (
	"cel.dev/cel-go/cel"
	"fmt"
)

func main() {
	e, err := cel.NewEnv(cel.OptionalTypes())
	if err != nil {
		panic(err)
	}
	for _, s := range []string{
		"[1][?0.5]", "[1][?0.0]", "[1][?1u]", "{}[?null]", "optional.of([1])[0.0]", "optional.ofNonZeroValue(0.0/0.0).hasValue()",
		"optional.none()[1 / 0]", "optional.none()[?1 / 0]", "optional.of({'x':optional.none()}).x.hasValue()",
		"optional.ofNonZeroValue(optional.none()).hasValue()", "optional.ofNonZeroValue(timestamp(0)).hasValue()",
		"optional.ofNonZeroValue(timestamp('0001-01-01T00:00:00Z')).hasValue()", "{?1/0:optional.none()}",
		"optional.of(optional.of({'x':1})).x", "optional.of(1).or(1)", "optional.of(1).orValue(optional.none())",
	} {
		a, i := e.Parse(s)
		if i.Err() != nil {
			fmt.Println(s, "parse", i.Err())
			continue
		}
		p, err := e.Program(a)
		if err != nil {
			fmt.Println(s, err)
			continue
		}
		v, _, err := p.Eval(map[string]interface{}{})
		fmt.Printf("%s => %v / %v\n", s, v, err)
	}
}
