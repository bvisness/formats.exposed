package png

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:strings"

// ----------------------------------------
// Main program setup

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

// ------------------------------------------------------
// PNG parsing

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

	// parse chunks
	for {
		data_len := parse_png_int32(&p, "chunk size") or_return
		chunk_type := parse_chunk_type(&p) or_return
		data := read_bytes(&p, data_len) or_return
		crc := read_bytes(&p, 4) or_return
		fmt.printfln(
			"%s: %d bytes (crc: %x%x%x%x)",
			string(chunk_type),
			data_len,
			crc[0],
			crc[1],
			crc[2],
			crc[3],
		)

		if string(chunk_type) == "IEND" {
			break
		}
	}

	return true
}

parse_png_int32 :: proc(p: ^Parser, thing: string) -> (v: int, ok: bool) {
	initial_cur := p.cur
	bytes := read_bytes(p, 4) or_return
	res, _ := endian.get_u32(bytes, .Big)
	if res > 0x7FFFFFFF {
		parser_err(
			p,
			initial_cur,
			fmt.aprintf("%s of %d exceeds PNG integer limit of 2^31-1", thing, res),
			.Warning,
		)
	}
	return int(res), true
}

parse_chunk_type :: proc(p: ^Parser) -> (type: []byte, ok: bool) {
	initial_cur := p.cur
	ty := read_bytes(p, 4) or_return
	for b in ty {
		char_ok := (0x41 <= b && b <= 0x5A) || (0x61 <= b && b <= 0x7A)
		if !char_ok {
			parser_err(
				p,
				initial_cur,
				fmt.aprintf("chunk type contains invalid byte %x", b),
				.Warning,
			)
		}
	}
	return ty, true
}

// ----------------------------------------------
// General parsing and utilities

Parser :: struct {
	buf:  []byte,
	out:  [dynamic]byte,
	errs: [dynamic]ParseError,
	cur:  int,
}

ParseError :: struct {
	loc:     int,
	level:   ErrorLevel,
	message: string,
}

ErrorLevel :: enum {
	Error,
	Warning,
}

parser_err :: proc(
	p: ^Parser,
	cur: int,
	msg: string,
	level: ErrorLevel = .Error,
	loc := #caller_location,
) -> bool {
	append(&p.errs, ParseError{loc = cur, level = level, message = msg}, loc)
	return false
}

expect_bytes :: proc(p: ^Parser, bs: []byte) -> bool {
	ok := true
	initial_cur := p.cur
	actual := read_bytes(p, len(bs)) or_return
	for b, i in bs {
		if actual[i] != b {
			ok = false
		}
	}
	if !ok {
		return parser_err(
			p,
			initial_cur,
			fmt.aprintf(
				"expected byte sequence \"%s\" but got \"%s\"",
				hexes(bs, context.temp_allocator),
				hexes(actual, context.temp_allocator),
			),
			.Error,
		)
	}

	return true
}

read_bytes :: proc(p: ^Parser, n: int) -> ([]byte, bool) {
	if len(p.buf[p.cur:]) < n {
		return nil, parser_err(
			p,
			p.cur,
			fmt.aprintf("expected %d bytes, but only %d bytes remain", n, len(p.buf[p.cur:])),
		)
	}
	res := p.buf[p.cur:p.cur + n]
	p.cur += n
	return res, true
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
