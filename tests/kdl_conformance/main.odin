// Runs the upstream KDL test suite (kdl-org/kdl tests/test_cases) against mead's parser.
// Usage: kdl_conformance <path-to-test_cases>
package kdl_conformance

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import kdl "../../kdl"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: kdl_conformance <test_cases directory> [-v]")
		os.exit(2)
	}
	verbose := len(args) > 2 && args[2] == "-v"
	root := args[1]
	input_dir, _ := os.join_path({root, "input"}, context.allocator)
	expected_dir, _ := os.join_path({root, "expected_kdl"}, context.allocator)
	infos, err := os.read_all_directory_by_path(input_dir, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", input_dir)
		os.exit(2)
	}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	passed, failed := 0, 0
	for info in infos {
		if !strings.has_suffix(info.name, ".kdl") {
			continue
		}
		data, _ := os.read_entire_file(info.fullpath, context.allocator)
		doc, perr, ok := kdl.parse(string(data))
		should_fail := strings.has_suffix(info.name, "_fail.kdl")
		if should_fail {
			if ok {
				failed += 1
				fmt.printfln("FAIL %s: parsed, but the case must fail", info.name)
			} else {
				passed += 1
			}
			continue
		}
		if !ok {
			failed += 1
			fmt.printfln("FAIL %s: %s at %d:%d", info.name, perr.msg, perr.line, perr.column)
			continue
		}
		expected_path, _ := os.join_path({expected_dir, info.name}, context.allocator)
		expected, _ := os.read_entire_file(expected_path, context.allocator)
		got := emit(doc)
		if got != string(expected) {
			failed += 1
			fmt.printfln("FAIL %s: output differs", info.name)
			if verbose {
				fmt.printfln("--- expected\n%s--- got\n%s---", string(expected), got)
			}
			continue
		}
		passed += 1
	}
	fmt.printfln("%d passed, %d failed", passed, failed)
	if failed > 0 {
		os.exit(1)
	}
}

emit :: proc(doc: kdl.Document) -> string {
	b := strings.builder_make()
	for n in doc.nodes {
		emit_node(&b, n, 0)
	}
	if len(doc.nodes) == 0 {
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

emit_node :: proc(b: ^strings.Builder, n: kdl.Node, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(b, "    ")
	}
	if n.has_type {
		fmt.sbprintf(b, "(%s)", kdl.format_string(n.type_name))
	}
	strings.write_string(b, kdl.format_string(n.name))
	for e in n.entries {
		if !e.is_prop {
			strings.write_byte(b, ' ')
			emit_value(b, e.value)
		}
	}
	// The rightmost duplicate property wins, then properties sort by name.
	props := make(map[string]kdl.Value)
	for e in n.entries {
		if e.is_prop {
			props[e.name] = e.value
		}
	}
	keys, _ := slice.map_keys(props)
	slice.sort(keys)
	for k in keys {
		fmt.sbprintf(b, " %s=", kdl.format_string(k))
		emit_value(b, props[k])
	}
	if len(n.children) > 0 {
		strings.write_string(b, " {\n")
		for c in n.children {
			emit_node(b, c, depth + 1)
		}
		for _ in 0 ..< depth {
			strings.write_string(b, "    ")
		}
		strings.write_string(b, "}")
	}
	strings.write_byte(b, '\n')
}

emit_value :: proc(b: ^strings.Builder, v: kdl.Value) {
	if v.has_type {
		fmt.sbprintf(b, "(%s)", kdl.format_string(v.type_name))
	}
	switch v.kind {
	case .String:
		strings.write_string(b, kdl.format_string(v.text))
	case .Integer:
		strings.write_string(b, integer_decimal(v.text))
	case .Float:
		strings.write_string(b, float_text(v.text))
	case .Bool, .Null, .Inf, .Neg_Inf, .NaN:
		strings.write_string(b, v.text)
	}
}

integer_decimal :: proc(text: string) -> string {
	s, _ := strings.remove_all(text, "_")
	negative := false
	if s[0] == '+' || s[0] == '-' {
		negative = s[0] == '-'
		s = s[1:]
	}
	radix := 10
	if len(s) > 2 && s[0] == '0' {
		switch s[1] {
		case 'x': radix = 16
		case 'o': radix = 8
		case 'b': radix = 2
		}
	}
	if radix == 10 {
		s = strings.trim_left(s, "0")
		if s == "" {
			s = "0"
		}
		return negative ? strings.concatenate({"-", s}) : s
	}
	acc: u128
	for c in s[2:] {
		d: u128
		switch c {
		case '0' ..= '9': d = u128(c - '0')
		case 'a' ..= 'f': d = u128(c - 'a' + 10)
		case 'A' ..= 'F': d = u128(c - 'A' + 10)
		}
		acc = acc * u128(radix) + d
	}
	return fmt.aprintf("%s%d", negative ? "-" : "", acc)
}

float_text :: proc(text: string) -> string {
	s, _ := strings.remove_all(text, "_")
	if s[0] == '+' {
		s = s[1:]
	}
	idx := strings.index_any(s, "eE")
	if idx < 0 {
		return s
	}
	mantissa, exponent := s[:idx], s[idx + 1:]
	if exponent[0] != '+' && exponent[0] != '-' {
		exponent = strings.concatenate({"+", exponent})
	}
	return strings.concatenate({mantissa, "E", exponent})
}
