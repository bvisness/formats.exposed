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
