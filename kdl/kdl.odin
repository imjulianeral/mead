/*
A KDL 2.0.0 reader for mead.

The parser keeps every entry in source order, including repeated properties.
KDL lets the last repeated property win, but mead's schema rejects repetition,
so callers must see the original property events. Nodes also record byte
offsets, which lets mead insert text into a manifest without disturbing comments.
*/
package kdl

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Value_Kind :: enum {
	String,
	Integer,
	Float,
	Bool,
	Null,
	Inf,
	Neg_Inf,
	NaN,
}

Value :: struct {
	kind:     Value_Kind,
	// Decoded text for strings. Source text for numbers, without the type annotation.
	text:     string,
	// Set when an integer fits in an i64.
	int_val:  i64,
	int_ok:   bool,
	float_val: f64,
	bool_val: bool,
	type_name: string,
	has_type: bool,
}

Entry :: struct {
	// Empty for arguments.
	name:    string,
	is_prop: bool,
	value:   Value,
	offset:  int,
}

Node :: struct {
	name:           string,
	type_name:      string,
	has_type:       bool,
	entries:        [dynamic]Entry,
	children:       [dynamic]Node,
	has_children:   bool,
	// Byte offset of the node's first character (its type annotation or name).
	offset:         int,
	// Byte offset just past the node's last component, before its terminator.
	end:            int,
	// Byte offsets of the children block braces when has_children is set.
	children_open:  int,
	children_close: int,
}

Document :: struct {
	nodes: [dynamic]Node,
}

Error :: struct {
	msg:    string,
	offset: int,
	line:   int,
	column: int,
}

@(private)
Parser :: struct {
	src:    string,
	pos:    int,
	failed: bool,
	err:    Error,
}

parse :: proc(src: string, allocator := context.allocator) -> (doc: Document, err: Error, ok: bool) {
	context.allocator = allocator
	p := Parser{src = src}
	if strings.has_prefix(src, "\xef\xbb\xbf") {
		p.pos = 3
	}
	if !check_literal_code_points(&p) {
		return {}, p.err, false
	}
	nodes, nodes_ok := parse_nodes(&p, false)
	if !nodes_ok {
		return {}, p.err, false
	}
	return Document{nodes = nodes}, {}, true
}

// Returns the 1-based line and column of a byte offset.
line_column :: proc(src: string, offset: int) -> (line, column: int) {
	line, column = 1, 1
	i := 0
	for i < offset && i < len(src) {
		r, size := utf8.decode_rune_in_string(src[i:])
		if r == '\r' && i + 1 < len(src) && src[i + 1] == '\n' {
			i += 2
			line += 1
			column = 1
			continue
		}
		if is_newline(r) {
			line += 1
			column = 1
		} else {
			column += 1
		}
		i += size
	}
	return
}

// Value accessors used by schema readers.

entry_string :: proc(e: Entry) -> (string, bool) {
	if e.value.kind != .String {
		return "", false
	}
	return e.value.text, true
}

// Writes a string as an identifier when KDL permits it, or as a quoted string.
format_string :: proc(s: string, allocator := context.allocator) -> string {
	if is_valid_identifier(s) {
		return strings.clone(s, allocator)
	}
	return quote_string(s, allocator)
}

quote_string :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case '\b': strings.write_string(&b, `\b`)
		case '\f': strings.write_string(&b, `\f`)
		case:
			if is_disallowed(r) || is_newline(r) {
				strings.write_string(&b, `\u{`)
				buf: [16]byte
				strings.write_string(&b, strconv.write_bits(buf[:], u64(r), 16, false, 64, strconv.digits, {}))
				strings.write_byte(&b, '}')
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

is_valid_identifier :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for r in s {
		if !is_identifier_char(r) {
			return false
		}
	}
	if looks_numeric(s) {
		return false
	}
	switch s {
	case "true", "false", "null", "inf", "-inf", "nan":
		return false
	}
	return true
}

// Character classes

is_unicode_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', ' ', 0x00A0, 0x1680, 0x2000 ..= 0x200A, 0x202F, 0x205F, 0x3000:
		return true
	}
	return false
}

is_newline :: proc(r: rune) -> bool {
	switch r {
	case '\r', '\n', 0x0085, 0x000B, 0x000C, 0x2028, 0x2029:
		return true
	}
	return false
}

is_disallowed :: proc(r: rune) -> bool {
	switch r {
	case 0x0000 ..= 0x0008, 0x000E ..= 0x001F, 0x007F, 0xD800 ..= 0xDFFF,
	     0x200E ..= 0x200F, 0x202A ..= 0x202E, 0x2066 ..= 0x2069, 0xFEFF:
		return true
	}
	return false
}

is_identifier_char :: proc(r: rune) -> bool {
	if is_unicode_space(r) || is_newline(r) || is_disallowed(r) {
		return false
	}
	switch r {
	case '\\', '/', '(', ')', '{', '}', ';', '[', ']', '"', '#', '=':
		return false
	}
	return true
}

@(private)
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// Reports whether a bare token starts like a number. Such tokens must parse as
// numbers because identifier strings cannot take these forms.
@(private)
looks_numeric :: proc(s: string) -> bool {
	at :: proc(s: string, i: int) -> byte {
		return i < len(s) ? s[i] : 0
	}
	c0 := at(s, 0)
	if is_digit(rune(c0)) {
		return true
	}
	if c0 == '+' || c0 == '-' {
		c1 := at(s, 1)
		if is_digit(rune(c1)) {
			return true
		}
		if c1 == '.' && is_digit(rune(at(s, 2))) {
			return true
		}
		return false
	}
	if c0 == '.' && is_digit(rune(at(s, 1))) {
		return true
	}
	return false
}

// Parser internals

@(private)
fail :: proc(p: ^Parser, offset: int, msg: string) -> bool {
	if !p.failed {
		p.failed = true
		line, col := line_column(p.src, offset)
		p.err = Error{msg = msg, offset = offset, line = line, column = col}
	}
	return false
}

@(private)
check_literal_code_points :: proc(p: ^Parser) -> bool {
	i := p.pos
	for i < len(p.src) {
		r, size := utf8.decode_rune_in_string(p.src[i:])
		if r == utf8.RUNE_ERROR && size <= 1 {
			return fail(p, i, "invalid UTF-8")
		}
		if is_disallowed(r) {
			return fail(p, i, "disallowed literal code point")
		}
		i += size
	}
	return true
}

@(private)
eof :: proc(p: ^Parser) -> bool {
	return p.pos >= len(p.src)
}

@(private)
peek :: proc(p: ^Parser, ahead := 0) -> rune {
	i := p.pos
	for _ in 0 ..< ahead {
		if i >= len(p.src) {
			return -1
		}
		_, size := utf8.decode_rune_in_string(p.src[i:])
		i += size
	}
	if i >= len(p.src) {
		return -1
	}
	r, _ := utf8.decode_rune_in_string(p.src[i:])
	return r
}

@(private)
advance :: proc(p: ^Parser) {
	if p.pos < len(p.src) {
		_, size := utf8.decode_rune_in_string(p.src[p.pos:])
		p.pos += size
	}
}

@(private)
starts_with :: proc(p: ^Parser, s: string) -> bool {
	return strings.has_prefix(p.src[p.pos:], s)
}

// Consumes one newline sequence, treating CRLF as a single newline.
@(private)
consume_newline :: proc(p: ^Parser) -> bool {
	r := peek(p)
	if r == '\r' && peek(p, 1) == '\n' {
		p.pos += 2
		return true
	}
	if is_newline(r) {
		advance(p)
		return true
	}
	return false
}

@(private)
skip_block_comment :: proc(p: ^Parser) -> bool {
	start := p.pos
	p.pos += 2
	depth := 1
	for depth > 0 {
		if eof(p) {
			return fail(p, start, "unterminated block comment")
		}
		if starts_with(p, "/*") {
			p.pos += 2
			depth += 1
		} else if starts_with(p, "*/") {
			p.pos += 2
			depth -= 1
		} else {
			advance(p)
		}
	}
	return true
}

@(private)
skip_line_comment :: proc(p: ^Parser) {
	p.pos += 2
	for !eof(p) {
		if consume_newline(p) {
			return
		}
		advance(p)
	}
}

// ws := unicode-space | multi-line-comment
@(private)
skip_ws :: proc(p: ^Parser) -> (consumed: bool, ok: bool) {
	for !eof(p) {
		if is_unicode_space(peek(p)) {
			advance(p)
			consumed = true
		} else if starts_with(p, "/*") {
			skip_block_comment(p) or_return
			consumed = true
		} else {
			break
		}
	}
	return consumed, true
}

// escline := '\\' ws* (single-line-comment | newline | eof)
@(private)
try_escline :: proc(p: ^Parser) -> (consumed: bool, ok: bool) {
	if peek(p) != '\\' {
		return false, true
	}
	start := p.pos
	advance(p)
	skip_ws(p) or_return
	if starts_with(p, "//") {
		skip_line_comment(p)
		return true, true
	}
	if consume_newline(p) || eof(p) {
		return true, true
	}
	return false, fail(p, start, "invalid line continuation")
}

@(private)
skip_node_space :: proc(p: ^Parser) -> (consumed: bool, ok: bool) {
	for {
		a := skip_ws(p) or_return
		b := try_escline(p) or_return
		if !a && !b {
			return consumed, true
		}
		consumed = true
	}
}

@(private)
skip_line_space :: proc(p: ^Parser) -> bool {
	for {
		a := skip_node_space(p) or_return
		b := consume_newline(p)
		c := false
		if starts_with(p, "//") {
			skip_line_comment(p)
			c = true
		}
		if !a && !b && !c {
			return true
		}
	}
}

@(private)
parse_nodes :: proc(p: ^Parser, in_children: bool) -> (nodes: [dynamic]Node, ok: bool) {
	for {
		skip_line_space(p) or_return
		if eof(p) {
			if in_children {
				return nil, fail(p, p.pos, "unclosed children block")
			}
			return nodes, true
		}
		if peek(p) == '}' {
			if in_children {
				return nodes, true
			}
			return nil, fail(p, p.pos, "unexpected '}'")
		}
		slashdash := false
		if starts_with(p, "/-") {
			p.pos += 2
			slashdash = true
			skip_line_space(p) or_return
			if eof(p) || peek(p) == '}' || starts_with(p, "/-") {
				return nil, fail(p, p.pos, "slashdash must precede a node")
			}
		}
		node := parse_node(p, in_children) or_return
		if !slashdash {
			append(&nodes, node)
		}
	}
}

@(private)
parse_node :: proc(p: ^Parser, in_children: bool) -> (node: Node, ok: bool) {
	node.offset = p.pos
	if peek(p) == '(' {
		node.type_name = parse_type(p) or_return
		node.has_type = true
		skip_node_space(p) or_return
	}
	name_pos := p.pos
	tok := parse_token(p) or_return
	if tok.kind != .String {
		return node, fail(p, name_pos, "node name must be a string")
	}
	node.name = tok.text
	node.end = p.pos

	seen_children := false
	seen_real_children := false
	for {
		had_space := skip_node_space(p) or_return
		if eof(p) {
			return node, true
		}
		r := peek(p)
		if r == ';' {
			advance(p)
			return node, true
		}
		if is_newline(r) {
			consume_newline(p)
			return node, true
		}
		if starts_with(p, "//") {
			skip_line_comment(p)
			return node, true
		}
		if r == '}' {
			if in_children {
				return node, true
			}
			return node, fail(p, p.pos, "unexpected '}'")
		}
		if starts_with(p, "/-") {
			p.pos += 2
			skip_line_space(p) or_return
			if peek(p) == '{' {
				discard: Node
				parse_children(p, &discard) or_return
				seen_children = true
				continue
			}
			if seen_children {
				return node, fail(p, p.pos, "arguments and properties must precede children")
			}
			if eof(p) || starts_with(p, "/-") {
				return node, fail(p, p.pos, "slashdash must precede an entry or children block")
			}
			parse_entry(p) or_return
			continue
		}
		if r == '{' {
			if seen_real_children {
				return node, fail(p, p.pos, "a node can have only one children block")
			}
			parse_children(p, &node) or_return
			seen_children = true
			seen_real_children = true
			node.end = p.pos
			continue
		}
		if seen_children {
			return node, fail(p, p.pos, "arguments and properties must precede children")
		}
		if !had_space {
			return node, fail(p, p.pos, "expected whitespace before entry")
		}
		entry := parse_entry(p) or_return
		append(&node.entries, entry)
		node.end = p.pos
	}
}

@(private)
parse_children :: proc(p: ^Parser, node: ^Node) -> bool {
	node.children_open = p.pos
	advance(p)
	children := parse_nodes(p, true) or_return
	node.children_close = p.pos
	advance(p) // '}'
	node.children = children
	node.has_children = true
	return true
}

@(private)
parse_type :: proc(p: ^Parser) -> (name: string, ok: bool) {
	start := p.pos
	advance(p) // '('
	skip_node_space(p) or_return
	tok := parse_token(p) or_return
	if tok.kind != .String {
		return "", fail(p, start, "type annotation must be a string")
	}
	skip_node_space(p) or_return
	if peek(p) != ')' {
		return "", fail(p, p.pos, "expected ')' after type annotation")
	}
	advance(p)
	return tok.text, true
}

@(private)
parse_entry :: proc(p: ^Parser) -> (entry: Entry, ok: bool) {
	entry.offset = p.pos
	if peek(p) == '(' {
		type_name := parse_type(p) or_return
		skip_node_space(p) or_return
		v := parse_token(p) or_return
		v.type_name = type_name
		v.has_type = true
		entry.value = v
		return entry, true
	}
	v := parse_token(p) or_return
	if v.kind == .String {
		saved := p.pos
		skip_node_space(p) or_return
		if peek(p) == '=' {
			advance(p)
			skip_node_space(p) or_return
			value_type: string
			has_type := false
			if peek(p) == '(' {
				value_type = parse_type(p) or_return
				has_type = true
				skip_node_space(p) or_return
			}
			value := parse_token(p) or_return
			value.type_name = value_type
			value.has_type = has_type
			entry.name = v.text
			entry.is_prop = true
			entry.value = value
			return entry, true
		}
		p.pos = saved
	}
	entry.value = v
	return entry, true
}

// Parses one string, number, or keyword value.
@(private)
parse_token :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	start := p.pos
	r := peek(p)
	switch {
	case r == -1:
		return v, fail(p, start, "unexpected end of input")
	case r == '"':
		v.kind = .String
		v.text = parse_quoted(p, 0) or_return
		return v, true
	case r == '#':
		hashes := 0
		for peek(p, hashes) == '#' {
			hashes += 1
		}
		if peek(p, hashes) == '"' {
			p.pos += hashes
			v.kind = .String
			v.text = parse_quoted(p, hashes) or_return
			return v, true
		}
		return parse_keyword(p)
	case is_identifier_char(r):
		for !eof(p) && is_identifier_char(peek(p)) {
			advance(p)
		}
		text := p.src[start:p.pos]
		if looks_numeric(text) {
			return parse_number(p, text, start)
		}
		switch text {
		case "true", "false", "null", "inf", "-inf", "nan":
			return v, fail(p, start, "keywords require a '#' prefix")
		}
		v.kind = .String
		v.text = text
		return v, true
	}
	return v, fail(p, start, "expected a value")
}

@(private)
parse_keyword :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	start := p.pos
	advance(p) // '#'
	for !eof(p) && is_identifier_char(peek(p)) {
		advance(p)
	}
	word := p.src[start:p.pos]
	switch word {
	case "#true":
		v.kind = .Bool
		v.bool_val = true
	case "#false":
		v.kind = .Bool
	case "#null":
		v.kind = .Null
	case "#inf":
		v.kind = .Inf
	case "#-inf":
		v.kind = .Neg_Inf
	case "#nan":
		v.kind = .NaN
	case:
		return v, fail(p, start, "unknown keyword")
	}
	v.text = word
	return v, true
}

@(private)
parse_number :: proc(p: ^Parser, text: string, start: int) -> (v: Value, ok: bool) {
	s := text
	negative := false
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
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
	v.text = text
	if radix != 10 {
		digits := s[2:]
		if len(digits) == 0 || digits[0] == '_' {
			return v, fail(p, start, "invalid number")
		}
		acc: i128
		overflow := false
		for c in digits {
			if c == '_' {
				continue
			}
			d := digit_value(c)
			if d < 0 || d >= radix {
				return v, fail(p, start, "invalid number")
			}
			if acc > (max(i128) - i128(d)) / i128(radix) {
				overflow = true
			}
			acc = acc * i128(radix) + i128(d)
		}
		v.kind = .Integer
		if !overflow && acc <= i128(max(i64)) {
			v.int_val = negative ? -i64(acc) : i64(acc)
			v.int_ok = true
		}
		return v, true
	}

	// decimal := integer ('.' integer)? exponent?
	i := 0
	scan_integer :: proc(s: string, i: ^int) -> bool {
		if i^ >= len(s) || !is_digit(rune(s[i^])) {
			return false
		}
		for i^ < len(s) && (is_digit(rune(s[i^])) || s[i^] == '_') {
			i^ += 1
		}
		return true
	}
	if !scan_integer(s, &i) {
		return v, fail(p, start, "invalid number")
	}
	is_float := false
	if i < len(s) && s[i] == '.' {
		i += 1
		if !scan_integer(s, &i) {
			return v, fail(p, start, "invalid number")
		}
		is_float = true
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i += 1
		}
		if !scan_integer(s, &i) {
			return v, fail(p, start, "invalid number")
		}
		is_float = true
	}
	if i != len(s) {
		return v, fail(p, start, "invalid number")
	}
	clean, _ := strings.remove_all(text, "_")
	if is_float {
		v.kind = .Float
		v.float_val, _ = strconv.parse_f64(clean)
	} else {
		v.kind = .Integer
		v.int_val, v.int_ok = strconv.parse_i64_of_base(clean, 10)
	}
	return v, true
}

@(private)
digit_value :: proc(c: rune) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

// Parses a quoted, raw, or multi-line string. The position is at the opening
// quote; any raw-string hashes have already been consumed.
@(private)
parse_quoted :: proc(p: ^Parser, hashes: int) -> (s: string, ok: bool) {
	start := p.pos
	raw := hashes > 0
	if starts_with(p, `"""`) {
		p.pos += 3
		if !consume_newline(p) {
			return "", fail(p, start, "a multi-line string must begin with a newline")
		}
		body_start := p.pos
		for {
			if eof(p) {
				return "", fail(p, start, "unterminated multi-line string")
			}
			if !raw && peek(p) == '\\' {
				advance(p)
				advance(p)
				continue
			}
			if starts_with(p, `"""`) && closing_hashes(p, 3, hashes) {
				break
			}
			advance(p)
		}
		body := p.src[body_start:p.pos]
		p.pos += 3 + hashes
		return dedent_multiline(p, body, raw, start)
	}

	advance(p) // '"'
	body_start := p.pos
	for {
		if eof(p) {
			return "", fail(p, start, "unterminated string")
		}
		r := peek(p)
		if !raw && r == '\\' {
			advance(p)
			// Escaped whitespace may span newlines.
			if is_newline(peek(p)) {
				consume_newline(p)
			} else {
				advance(p)
			}
			continue
		}
		if r == '"' && closing_hashes(p, 1, hashes) {
			break
		}
		if is_newline(r) {
			if !raw {
				// A newline is valid only inside escaped whitespace, which the
				// escape branch above consumes together with its backslash.
				if !inside_ws_escape(p.src[body_start:p.pos]) {
					return "", fail(p, p.pos, "a single-line string cannot contain a literal newline")
				}
				consume_newline(p)
				continue
			}
			return "", fail(p, p.pos, "a single-line string cannot contain a literal newline")
		}
		advance(p)
	}
	body := p.src[body_start:p.pos]
	p.pos += 1 + hashes
	if raw {
		return strings.clone(body), true
	}
	return unescape(p, body, body_start, true)
}

// Reports whether the text ends within an escaped-whitespace run.
@(private)
inside_ws_escape :: proc(text: string) -> bool {
	i := len(text)
	for i > 0 {
		r, size := utf8.decode_last_rune_in_string(text[:i])
		if is_unicode_space(r) || is_newline(r) {
			i -= size
			continue
		}
		if r != '\\' {
			return false
		}
		// The backslash must not itself be escaped.
		n := 0
		for j := i - 1; j >= 0 && text[j] == '\\'; j -= 1 {
			n += 1
		}
		return n % 2 == 1
	}
	return false
}

@(private)
closing_hashes :: proc(p: ^Parser, quotes: int, hashes: int) -> bool {
	rest := p.src[p.pos + quotes:]
	if len(rest) < hashes {
		return false
	}
	for i in 0 ..< hashes {
		if rest[i] != '#' {
			return false
		}
	}
	return true
}

// Removes escaped whitespace and keeps all other escapes intact.
@(private)
remove_ws_escapes :: proc(body: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(body) {
		if body[i] == '\\' && i + 1 < len(body) {
			r, _ := utf8.decode_rune_in_string(body[i + 1:])
			if is_unicode_space(r) || is_newline(r) {
				i += 1
				for i < len(body) {
					r2, size := utf8.decode_rune_in_string(body[i:])
					if !is_unicode_space(r2) && !is_newline(r2) {
						break
					}
					i += size
				}
				continue
			}
			_, size := utf8.decode_rune_in_string(body[i + 1:])
			strings.write_string(&b, body[i:i + 1 + size])
			i += 1 + size
			continue
		}
		strings.write_byte(&b, body[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private)
split_lines :: proc(s: string) -> [dynamic]string {
	lines: [dynamic]string
	start := 0
	i := 0
	for i < len(s) {
		r, size := utf8.decode_rune_in_string(s[i:])
		if r == '\r' && i + 1 < len(s) && s[i + 1] == '\n' {
			append(&lines, s[start:i])
			i += 2
			start = i
			continue
		}
		if is_newline(r) {
			append(&lines, s[start:i])
			i += size
			start = i
			continue
		}
		i += size
	}
	append(&lines, s[start:])
	return lines
}

@(private)
all_space :: proc(s: string) -> bool {
	for r in s {
		if !is_unicode_space(r) {
			return false
		}
	}
	return true
}

@(private)
dedent_multiline :: proc(p: ^Parser, body: string, raw: bool, start: int) -> (s: string, ok: bool) {
	text := raw ? body : remove_ws_escapes(body)
	lines := split_lines(text)
	prefix := lines[len(lines) - 1]
	if !all_space(prefix) {
		return "", fail(p, start, "the closing line of a multi-line string may contain only whitespace")
	}
	b := strings.builder_make()
	for line, i in lines[:len(lines) - 1] {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		if all_space(line) {
			continue
		}
		if !strings.has_prefix(line, prefix) {
			return "", fail(p, start, "multi-line string lines must start with the closing line's indentation")
		}
		strings.write_string(&b, line[len(prefix):])
	}
	result := strings.to_string(b)
	if raw {
		return result, true
	}
	return unescape(p, result, start, false)
}

@(private)
unescape :: proc(p: ^Parser, body: string, offset: int, handle_ws: bool) -> (s: string, ok: bool) {
	b := strings.builder_make()
	i := 0
	for i < len(body) {
		c := body[i]
		if c != '\\' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if i + 1 >= len(body) {
			return "", fail(p, offset + i, "invalid escape")
		}
		next, next_size := utf8.decode_rune_in_string(body[i + 1:])
		switch next {
		case 'n':  strings.write_byte(&b, '\n')
		case 'r':  strings.write_byte(&b, '\r')
		case 't':  strings.write_byte(&b, '\t')
		case '\\': strings.write_byte(&b, '\\')
		case '"':  strings.write_byte(&b, '"')
		case 'b':  strings.write_byte(&b, '\b')
		case 'f':  strings.write_byte(&b, '\f')
		case 's':  strings.write_byte(&b, ' ')
		case 'u':
			j := i + 2
			if j >= len(body) || body[j] != '{' {
				return "", fail(p, offset + i, "invalid unicode escape")
			}
			j += 1
			value := 0
			digits := 0
			for j < len(body) && body[j] != '}' {
				d := digit_value(rune(body[j]))
				if d < 0 || digits >= 6 {
					return "", fail(p, offset + i, "invalid unicode escape")
				}
				value = value * 16 + d
				digits += 1
				j += 1
			}
			if j >= len(body) || digits == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
				return "", fail(p, offset + i, "invalid unicode escape")
			}
			strings.write_rune(&b, rune(value))
			i = j + 1
			continue
		case:
			if handle_ws && (is_unicode_space(next) || is_newline(next)) {
				i += 1
				for i < len(body) {
					r, size := utf8.decode_rune_in_string(body[i:])
					if !is_unicode_space(r) && !is_newline(r) {
						break
					}
					i += size
				}
				continue
			}
			return "", fail(p, offset + i, "invalid escape")
		}
		i += 1 + next_size
	}
	return strings.to_string(b), true
}
