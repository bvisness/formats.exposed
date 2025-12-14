# TODO

- [ ] Decide what formats to start with
  - some JSON-based format could exercise the layers idea in a valuable way
  - binary formats are perhaps the more valuable thing to communicate though
  - network protocols are very interesting but users likely won't have data on hand in a way that is useful
    - someday could have a server or something actually perform a request, to streamline this, but it still seems dubious and people would probably just want to upload a trace somehow.
  - PDF is probably insanely complicated and a poor starting point
  - It is decided for now: PNG, GIF, BMP. JPG once the others work.
    - BMP is actually way more complicated than expected. Maybe drop it. PNG, GIF, and WEBP?


## Thoughts

- We want to be able to view different parts of files in various sub-encodings. For example package.json is raw bytes, then UTF-8 (or other encodings), then JSON, then npm's schema. To capture all this we likely will want the ability to block off ranges of the file as being in particular encodings, e.g. bytes 4-end are UTF-8 after some magic number. We probably need not explicitly iterate over all unicode codepoints and explicitly dump them during the actual parse. Some formats can be done "lazily" by formats.exposed, and indeed I think this will be important for handling things like compressed chunks of PNG data (which can be easily viewed in their compressed form as raw bytes, and their uncompressed form as raw bytes, but where the details of decoding zlib are not in scope for the PNG decoder itself).
  - Notably, it's possible that the data in a particular range may not be valid, e.g. we may _know_ that some data is supposed to be UTF-8 but we find it has unpaired surrogates. This shouldn't catastrophically break the system.

- Should probably use mime types for identifying various types of content wherever possible.

- App architecture: SPA-ish. Landing page with a data type detector and the ability to dynamically load the UI and decoder for any data type. Can use history API shenanigans to switch to a new URL when a particular file type is dropped. Can't do actual page navigation without losing the File though.


## Schema

- Parse: record
  - strs: [][]byte
  - docs: []Document
  - regions: []Region

- Document: record
  - id: i32
  - name: Str
  - data?: []byte
  - span?: Span

- Region: record
  - doc: i32
  - span: Span
  - kind?: Str

- Span: [start: i32, end: i32]

- Str: union
  - 0x00 i32 (interned)
  - 0x01 []byte (raw)

- i32: 4 bytes, little-endian

- array[T]: [len: i32, data: [len]T]

Man, is any of this worthwhile? Or reusable? I have to write ad-hoc visuals for everything anyway, so do I really need some kind of universal document description format here?

What would probably be helpful is a simple universal key/value format, or at least a few core types that I can reuse parse functions for (e.g. ints, strings, spans).

## Format breakdowns

- PNG
  - Layer 1: bytes
  - Layer 2: sections
  - Layer 3: png semantics
    - IDAT (zlib(scanlines))
    - scanlines (image bytes):
      - Layer 1: bytes
      - Layer 2: array of (filter type, scanline)
      - Layer 3: filter types etc.
        - image bytes
          - Layer 3: colors as defined by IHDR info

- zlib
  - Layer 1: ???
  - Layer 2: ???
  - Layer 3: zlib format
    - Compressed data (anything, decided by zlib user)
