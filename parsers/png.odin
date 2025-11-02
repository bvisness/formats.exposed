package png

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

ctx := runtime.default_context()
when ODIN_DEBUG {
	track: mem.Tracking_Allocator
}

main :: proc() {
	when ODIN_DEBUG {
		mem.tracking_allocator_init(&track, ctx.allocator)
		ctx.allocator = mem.tracking_allocator(&track)
	}
}

@(export)
debugcheck :: proc "contextless" () {
	context = ctx

	when ODIN_DEBUG {
		if len(track.allocation_map) > 0 {
			for _, entry in track.allocation_map {
				fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}
}

// ------------------------------------------------------

Parser :: struct {
	buf:  []byte,
	out:  [dynamic]byte,
	errs: [dynamic]ParseError,
	cur:  int,
}

ParseError :: struct {
	loc:     int,
	message: string,
}

input: []byte
result: [dynamic]byte
errs: [dynamic]ParseError

@(export)
alloc :: proc "contextless" (n: int) -> ^byte {
	context = ctx
	input = make([]byte, n)
	return &input[0]
}

@(export)
parse :: proc "contextless" () -> bool {
	context = ctx

	p := Parser {
		buf  = input,
		out  = make([dynamic]byte),
		errs = make([dynamic]ParseError),
		cur  = 0,
	}
	defer {
		result = p.out
		errs = p.errs
	}

	expect_bytes(&p, {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}) or_return

	// free_all(context.temp_allocator)
	return true
}

parser_err :: proc(p: ^Parser, cur: int, msg: string, loc := #caller_location) -> bool {
	append(&p.errs, ParseError{loc = cur, message = msg}, loc)
	return false
}

expect_bytes :: proc(p: ^Parser, bs: []byte) -> bool {
	if len(p.buf[p.cur:]) < len(bs) {
		return parser_err(
			p,
			p.cur,
			fmt.aprintf(
				"expected %d bytes, but only %d bytes remain",
				len(bs),
				len(p.buf[p.cur:]),
			),
		)
	}

	ok := true
	initial_cur := p.cur
	for b in bs {
		if p.buf[p.cur] != b {
			ok = false
		}
		p.cur += 1
	}
	if !ok {
		actual := hexes(p.buf[initial_cur:initial_cur + len(bs)], context.temp_allocator)
		expected := hexes(bs, context.temp_allocator)
		return parser_err(
			p,
			initial_cur,
			fmt.aprintf("expected byte sequence \"%s\" but got \"%s\"", expected, actual),
		)
	}
	assert(p.cur == initial_cur + len(bs))

	return true
}

hexes :: proc(data: []byte, allocator := context.allocator) -> string {
	runes := []rune{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'}

	sb := strings.builder_make(context.temp_allocator)
	for b, i in data {
		if i > 0 {
			strings.write_rune(&sb, ' ')
		}
		strings.write_rune(&sb, runes[b >> 4]) // high half
		strings.write_rune(&sb, runes[b & 0x0F]) // low half
	}
	return strings.clone(strings.to_string(sb), allocator)
}

@(export)
get_result :: proc "contextless" () -> ^byte {
	if len(result) == 0 {
		return nil
	}
	return &result[0]
}

@(export)
get_result_len :: proc "contextless" () -> int {
	return len(result)
}

@(export)
print_errors :: proc "contextless" () {
	context = ctx
	for err in errs {
		fmt.printfln("at offset %d: %s", err.loc, err.message)
	}
}
