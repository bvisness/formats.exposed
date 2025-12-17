package png

import "base:runtime"
import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:slice"
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
	if len(out) == 0 {
		return nil
	}
	return &out[0]
}

@(export)
get_result_len :: proc "contextless" () -> int {
	return len(out)
}

@(export)
print_errors :: proc "contextless" () {
	context = ctx
	if len(errs) == 0 {
		fmt.println("no errors")
	} else {
		fmt.println("ERRORS:")
		for err in errs {
			fmt.printfln("at offset %d: %s", err.loc, err.message)
		}
	}
}

// ------------------------------------------------------
// PNG parsing

input: []byte
out: [dynamic]byte
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
		out  = &out,
		errs = &errs,
		cur  = 0,
	}

	expect_bytes(&p, {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, "magic") or_return

	ihdr: IHDR
	plte: Maybe(PLTE)
	idats := make([dynamic][]byte) // note that all IDATs together form a single zlib datastream
	gama: Maybe(int)
	srgb: Maybe(u8)
	phys: Maybe(PHYS)

	// parse chunks
	chunks: for {
		data_cur, crc_cur: int

		data_len := parse_png_int32(&p, "chunk size") or_return
		chunk_type := parse_chunk_type(&p) or_return
		data := read_bytes(&p, data_len, "chunk data", &data_cur) or_return
		expected_crc := parse_u32(&p, "crc", &crc_cur) or_return
		actual_crc := crc(chunk_type.name, data)
		if expected_crc != actual_crc {
			parser_err(
				&p,
				crc_cur,
				fmt.aprintf("bad CRC: got %d, expected %d", actual_crc, expected_crc),
				.Warning,
			)
		}
		fmt.printfln("%s: %d bytes", string(chunk_type.name), data_len)

		chunk_parser := make_subparser(&p, data, data_cur)
		switch string(chunk_type.name) {
		case "IHDR":
			ihdr, _ = parse_ihdr(&chunk_parser)
			fmt.printfln("%#v", ihdr)
		case "PLTE":
			plte, _ = parse_plte(&chunk_parser)
			fmt.printfln("%#v", plte)
		case "IDAT":
			idat, _ := parse_idat(&chunk_parser)
			// fmt.printfln("%#v", idat)
			append(&idats, idat)
		case "IEND":
			break chunks

		// Color space info
		case "gAMA":
			gama, _ = parse_gama(&chunk_parser)
			fmt.printfln("%d", gama)
		case "sRGB":
			srgb, _ = parse_srgb(&chunk_parser)
			fmt.printfln("%d", srgb)

		// Miscellaneous info
		case "pHYs":
			phys, _ = parse_phys(&chunk_parser)
			fmt.printfln("%#v", phys)
		}
	}

	filtered_data: []byte
	{
		data_compressed := slice.concatenate(idats[:])

		buf: bytes.Buffer
		err := zlib.inflate(input = data_compressed, buf = &buf)
		defer bytes.buffer_destroy(&buf)
		if err != nil {
			fmt.printf("\nError: %v\n", err)
		}
		filtered_data = slice.clone(bytes.buffer_to_bytes(&buf))
	}
	fmt.printfln("Decompressed data: %d bytes", len(filtered_data))

	image_bytes: []byte
	{
		scanlineParser := Parser {
			buf  = filtered_data,
			out  = &out, // TODO: What do we do with output data and errors for a different byte source entirely?
			errs = &errs,
			cur  = 0,
		}
		image_bytes = parse_scanlines(&scanlineParser, ihdr) or_return
	}

	// TODO: Iterate with bit depth in mind. For now our test image is 8-bit RGB anyway.
	image_rgba := make([]byte, ihdr.width * ihdr.height * 4) // RGBA for the browser
	for r in 0 ..< ihdr.height {
		for c in 0 ..< ihdr.width {
			// TODO: This all only works because we have a bit depth of 8. Again, iterate with bit depth in mind.
			srcPix :=
				r * ihdr.width * entries_per_pixel(ihdr.color_type) +
				c * entries_per_pixel(ihdr.color_type)
			dstPix := r * ihdr.width * 4 + c * 4

			switch ihdr.color_type {
			case 0:
			// greyscale
			// TODO
			case 2:
				// truecolor
				image_rgba[dstPix + 0] = image_bytes[srcPix + 0]
				image_rgba[dstPix + 1] = image_bytes[srcPix + 1]
				image_rgba[dstPix + 2] = image_bytes[srcPix + 2]
				image_rgba[dstPix + 3] = 255
			case 3:
			// indexed-color
			// TODO
			case 4:
			// greyscale with alpha
			// TODO
			case 6:
				// truecolor with alpha
				image_rgba[dstPix + 0] = image_bytes[srcPix + 0]
				image_rgba[dstPix + 1] = image_bytes[srcPix + 1]
				image_rgba[dstPix + 2] = image_bytes[srcPix + 2]
				image_rgba[dstPix + 3] = image_bytes[srcPix + 3]
			}
		}
	}

	// TODO: We really should just be dumping all the info we parsed in some standard format. But I'm
	// not quite ready to jump into that.
	write_int(&out, ihdr.width)
	write_int(&out, ihdr.height)
	write_raw_bytes(&out, image_rgba)

	return true
}

parse_u32 :: proc(p: ^Parser, thing: string, cur: ^int = nil) -> (v: u32, ok: bool) {
	initial_cur := p.cur
	bytes := read_bytes(p, 4, thing, cur) or_return
	res, _ := endian.get_u32(bytes, .Big)
	return res, true
}

parse_png_int32 :: proc(p: ^Parser, thing: string, cur: ^int = nil) -> (v: int, ok: bool) {
	initial_cur := p.cur
	bytes := read_bytes(p, 4, thing, cur) or_return
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

ChunkType :: struct {
	name:         []byte,
	ancillary:    bool,
	private:      bool,
	reserved:     bool,
	safe_to_copy: bool,
}

parse_chunk_type :: proc(p: ^Parser) -> (type: ChunkType, ok: bool) {
	initial_cur := p.cur
	name := read_bytes(p, 4, "chunk type") or_return
	for b in name {
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
	ty := ChunkType {
		name         = name,
		ancillary    = name[0] & 0b10000 != 0,
		private      = name[1] & 0b10000 != 0,
		reserved     = name[2] & 0b10000 != 0,
		safe_to_copy = name[3] & 0b10000 != 0,
	}
	return ty, true
}

IHDR :: struct {
	width:              int,
	height:             int,
	bit_depth:          u8,
	color_type:         u8,
	compression_method: u8,
	filter_method:      u8,
	interlace_method:   u8,
}

valid_bit_depths := []struct {
	name:   string,
	depths: []u8,
} {
	{"greyscale", {1, 2, 4, 8, 16}},
	{"INVALID", {}}, // type 1 is not used
	{"truecolor", {8, 16}},
	{"indexed-color", {1, 2, 4, 8}},
	{"greyscale with alpha", {8, 16}},
	{"INVALID", {}}, // type 5 is not used
	{"truecolor with alpha", {8, 16}},
}

parse_ihdr :: proc(p: ^Parser, cur: ^int = nil) -> (ihdr: IHDR, ok: bool) {
	initial_cur := p.cur
	if cur != nil {
		cur^ = initial_cur
	}
	bit_depth_cur, color_type_cur, compression_method_cur, filter_method_cur, interlace_method_cur: int

	ihdr = IHDR {
		width              = parse_png_int32(p, "width") or_return,
		height             = parse_png_int32(p, "height") or_return,
		bit_depth          = read_byte(p, "bit depth", &bit_depth_cur) or_return,
		color_type         = read_byte(p, "color type", &color_type_cur) or_return,
		compression_method = read_byte(p, "compression method", &compression_method_cur) or_return,
		filter_method      = read_byte(p, "filter method", &filter_method_cur) or_return,
		interlace_method   = read_byte(p, "interlace method", &interlace_method_cur) or_return,
	}

	// Validate bit depth
	if !slice.contains([]u8{1, 2, 4, 8, 16}, ihdr.bit_depth) {
		parser_err(
			p,
			bit_depth_cur,
			fmt.aprintf("invalid bit depth: %d", ihdr.bit_depth),
			.Warning,
		)
	}

	// Validate bit depths for color types
	if int(ihdr.color_type) >= len(valid_bit_depths) {
		parser_err(
			p,
			color_type_cur,
			fmt.aprintf("invalid color type: %d", ihdr.color_type),
			.Warning,
		)
	} else {
		entry := valid_bit_depths[ihdr.color_type]
		if !slice.contains(entry.depths, ihdr.bit_depth) {
			parser_err(
				p,
				color_type_cur,
				fmt.aprintf("invalid color type for %s: %d", entry.name, ihdr.color_type),
				.Warning,
			)
		}
	}

	// Validate methods
	if ihdr.compression_method != 0 {
		parser_err(
			p,
			compression_method_cur,
			fmt.aprintf("invalid compression method: %d", ihdr.compression_method),
			.Warning,
		)
	}
	if ihdr.filter_method != 0 {
		parser_err(
			p,
			filter_method_cur,
			fmt.aprintf("invalid filter method: %d", ihdr.filter_method),
			.Warning,
		)
	}
	if ihdr.interlace_method != 0 && ihdr.interlace_method != 1 {
		parser_err(
			p,
			filter_method_cur,
			fmt.aprintf("invalid interlace method: %d", ihdr.interlace_method),
			.Warning,
		)
	}

	return ihdr, true
}

PLTE :: struct {
	entries: []PLTEEntry,
}

PLTEEntry :: struct {
	R, G, B: u8,
}

parse_plte :: proc(p: ^Parser, cur: ^int = nil) -> (plte: PLTE, ok: bool) {
	initial_cur := p.cur
	if cur != nil {
		cur^ = initial_cur
	}

	// We can do this because we call this with a subparser scoped to the chunk data.
	if len(p.buf) % 3 != 0 {
		parser_err(
			p,
			initial_cur,
			fmt.aprintf("invalid PLTE data: data size of %d not divisible by 3", len(p.buf)),
		)
		return
	}

	num_entries := len(p.buf) / 3
	if num_entries < 1 || 256 < num_entries {
		parser_err(
			p,
			initial_cur,
			fmt.aprintf(
				"invalid PLTE data: invalid number of entries (got %d, expected 1 to 256)",
				num_entries,
			),
			.Warning,
		)
	}
	plte.entries = make([]PLTEEntry, num_entries)
	for i in 0 ..< num_entries {
		plte.entries[i] = {
			R = must(read_byte(p, "PLTE entry R")),
			G = must(read_byte(p, "PLTE entry G")),
			B = must(read_byte(p, "PLTE entry B")),
		}
	}

	return plte, true
}

parse_idat :: proc(p: ^Parser, cur: ^int = nil) -> ([]byte, bool) {
	if cur != nil {
		cur^ = p.cur
	}

	// Shortcut this one.
	return p.buf, true
}

parse_gama :: proc(p: ^Parser, cur: ^int = nil) -> (int, bool) {
	if cur != nil {
		cur^ = p.cur
	}
	return parse_png_int32(p, "gAMA gamma value")
}

parse_srgb :: proc(p: ^Parser, cur: ^int = nil) -> (u8, bool) {
	if cur != nil {
		cur^ = p.cur
	}
	return read_byte(p, "sRGB rendering intent")
}

PHYS :: struct {
	x, y: int,
	unit: u8,
}

parse_phys :: proc(p: ^Parser, cur: ^int = nil) -> (phys: PHYS, ok: bool) {
	phys = PHYS {
		x    = parse_png_int32(p, "pHYs X") or_return,
		y    = parse_png_int32(p, "pHYs Y") or_return,
		unit = read_byte(p, "pHYs unit") or_return,
	}
	return phys, true
}

parse_scanlines :: proc(
	p: ^Parser,
	ihdr: IHDR,
	cur: ^int = nil,
) -> (
	filtered_bytes: []byte,
	ok: bool,
) {
	num_scanline_bits := ihdr.width * entries_per_pixel(ihdr.color_type) * int(ihdr.bit_depth)
	num_scanline_bits += num_scanline_bits % 8
	num_scanline_bytes := num_scanline_bits / 8

	// The spec says that to find a (and c) you must look at "the byte
	// corresponding to x in the pixel immediately before the pixel containing x
	// (or the byte immediately before x, when the bit depth is less than 8)".
	//
	// This is confusingly worded but sensible once you break it down.
	//
	// Suppose you have the following scanline using the Sub filter (with indices
	// labeled):
	//
	//     [0, 0, 255, 0, 0, 0]
	//      0  1  2    3  4  5
	//
	// This should result in two blue pixels, because each entry refers to the
	// byte three bytes prior. This is intuitive: red minus red, green minus
	// green, blue minus blue.
	//
	// However, since deltas are computed on a byte-by-byte basis, this naturally
	// leads to two edge cases:
	//  - With a bit depth of 16, each channel is spread across two bytes, so
	//    deltas are computed bytewise against the previous bytes for that
	//    channel (high minus high, low minus low).
	//  - With a bit depth less than 8, pixels are packed, so deltas are simply
	//    computed from the previous byte.
	//
	// Here we compute an offset that we can add or subtract to get this
	// neighboring byte within a row.
	offset_to_prev_pixel :=
		ihdr.bit_depth < 8 ? 1 : (int(ihdr.bit_depth) / 8 * entries_per_pixel(ihdr.color_type))

	res := make([]byte, num_scanline_bytes * ihdr.height)
	for row in 0 ..< ihdr.height {
		ft_cur: int
		ft := read_byte(p, "filter type", &ft_cur) or_return
		scanline := read_bytes(p, num_scanline_bytes, "scanline bytes") or_return

		// For naming, see https://www.w3.org/TR/png-3/#9Filter-types

		read_scanline: for x, col in scanline {
			x_idx := row * num_scanline_bytes + col
			a := col < offset_to_prev_pixel ? 0 : res[x_idx - offset_to_prev_pixel]
			b := row == 0 ? 0 : res[x_idx - num_scanline_bytes]
			c :=
				col < offset_to_prev_pixel ? 0 : (row == 0 ? 0 : res[x_idx - num_scanline_bytes - offset_to_prev_pixel])

			switch ft {
			case 0:
				// none
				fmt.println("no filter")
				res[x_idx] = x
			case 1:
				// sub
				fmt.println("sub")
				res[x_idx] = x + a
			case 2:
				// up
				fmt.println("up")
				res[x_idx] = x + b
			case 3:
				// average
				fmt.println("average")
				res[x_idx] = x + byte((int(a) + int(b)) / 2)
			case 4:
				// Paeth
				fmt.println("Paeth")
				p := int(a) + int(b) - int(c)
				pa := abs(p - int(a))
				pb := abs(p - int(b))
				pc := abs(p - int(c))
				Pr: int
				if pa <= pb && pa <= pc {
					Pr = int(a)
				} else if pb <= pc {
					Pr = int(b)
				} else {
					Pr = int(c)
				}
				res[x_idx] = x + byte(Pr)
			case:
				parser_err(p, ft_cur, fmt.aprintf("bad filter type for row %d: %d", row, ft))
				break read_scanline
			}
		}
	}

	return res, true
}

entries_per_pixel :: proc(color_type: u8) -> int {
	switch color_type {
	case 0, 3:
		// greyscale, indexed-color
		return 1
	case 2:
		// truecolor
		return 3
	case 4:
		// greyscale with alpha
		return 2
	case 6:
		// truecolor with alpha
		return 4
	case:
		return -1
	}
}


// --------------------------------
// CRC impl (adapted from Appendix D of the PNG spec)

// Table of CRCs of all 8-bit messages.
crc_table := proc "contextless" () -> (res: [256]u32) {
	for n in 0 ..< 256 {
		c := u32(n)
		for k in 0 ..< 8 {
			if c & 1 != 0 {
				c = 0xEDB88320 ~ (c >> 1)
			} else {
				c = c >> 1
			}
		}
		res[n] = c
	}
	return
}()

// Update a running CRC with the bytes buf[0..len-1]--the CRC
// should be initialized to all 1's, and the transmitted value
// is the 1's complement of the final running CRC (see the
// crc() routine below).
update_crc :: proc(crc: u32, buf: []byte) -> u32 {
	c := crc
	for b in buf {
		c = crc_table[(c ~ u32(b)) & 0xFF] ~ (c >> 8)
	}
	return c
}

crc :: proc(bufs: ..[]byte) -> u32 {
	res: u32 = 0xFFFFFFFF
	for buf in bufs {
		res = update_crc(res, buf)
	}
	return res ~ 0xFFFFFFFF
}


// ----------------------------------------------
// General parsing and utilities

Parser :: struct {
	buf:        []byte,
	out:        ^[dynamic]byte,
	errs:       ^[dynamic]ParseError,
	cur:        int,

	// A value to offset the cursor by when reporting errors.
	// Used by subparsers.
	cur_offset: int,
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
	append(p.errs, ParseError{loc = cur, level = level, message = msg}, loc)
	return false
}

make_subparser :: proc(p: ^Parser, buf: []byte, buf_cur: int) -> Parser {
	return Parser{buf = buf, out = p.out, errs = p.errs, cur = 0, cur_offset = -buf_cur}
}

expect_bytes :: proc(p: ^Parser, bs: []byte, thing: string, cur: ^int = nil) -> bool {
	ok := true
	initial_cur := p.cur
	actual := read_bytes(p, len(bs), thing, cur) or_return
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
				"%s: expected byte sequence \"%s\" but got \"%s\"",
				thing,
				hexes(bs),
				hexes(actual),
			),
			.Error,
		)
	}

	return true
}

read_bytes :: proc(p: ^Parser, n: int, thing: string, cur: ^int = nil) -> ([]byte, bool) {
	if cur != nil {
		cur^ = p.cur
	}

	if len(p.buf[p.cur:]) < n {
		return nil, parser_err(
			p,
			p.cur + p.cur_offset,
			fmt.aprintf(
				"%s: expected %d bytes, but only %d bytes remain",
				thing,
				n,
				len(p.buf[p.cur:]),
			),
		)
	}
	res := p.buf[p.cur:p.cur + n]
	p.cur += n
	return res, true
}

read_byte :: proc(p: ^Parser, thing: string, cur: ^int = nil) -> (byte, bool) {
	bytes, ok := read_bytes(p, 1, thing, cur)
	if !ok {
		return 0, false
	}
	return bytes[0], true
}

write_str :: proc(out: ^[dynamic]byte, str: string) -> runtime.Allocator_Error {
	write_bytes(out, transmute([]byte)str) or_return
	return .None
}

write_int :: proc(out: ^[dynamic]byte, n: int) -> runtime.Allocator_Error {
	return write_i32(out, i32(n))
}

write_i32 :: proc(out: ^[dynamic]byte, n: i32) -> runtime.Allocator_Error {
	dst := _grow(out, 4) or_return
	must(endian.put_i32(dst, .Little, n))
	return .None
}

write_bytes :: proc(out: ^[dynamic]byte, bytes: []byte) -> runtime.Allocator_Error {
	write_int(out, len(bytes)) or_return
	write_raw_bytes(out, bytes) or_return
	return .None
}

write_raw_bytes :: proc(out: ^[dynamic]byte, bytes: []byte) -> runtime.Allocator_Error {
	dst := _grow(out, len(bytes)) or_return
	copy(dst, bytes)
	return .None
}

_grow :: proc(out: ^[dynamic]byte, n: int) -> ([]byte, runtime.Allocator_Error) {
	start := len(out)
	if err := resize(out, len(out) + n); err != .None {
		return nil, err
	}
	return out[start:], .None
}

hexes :: proc(data: []byte, allocator := context.allocator) -> string {
	runes := []rune{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'}

	sb := strings.builder_make()
	for b, i in data {
		if i > 0 {
			strings.write_rune(&sb, ' ')
		}
		strings.write_rune(&sb, runes[b >> 4]) // high half
		strings.write_rune(&sb, runes[b & 0x0F]) // low half
	}
	return strings.clone(strings.to_string(sb), allocator)
}

must1 :: proc(ok: bool) {
	assert(ok)
}

must2 :: proc(v: $T, ok: bool) -> T {
	assert(ok)
	return v
}

must :: proc {
	must1,
	must2,
}
