# bend-ipp

A pure encode/decode library for the Internet Printing Protocol (IPP) in
[Bend 2](https://github.com/bendlang/bend): RFC 8010 binary encoding and RFC
8011 operations, over byte lists. It builds Get-Printer-Attributes, Print-Job
and Validate-Job requests, decodes any IPP message, and has accessors for the
common status fields (`printer-state`, `marker-levels`, ...).

The codec (`src/ipp.bend`) is pure: no sockets, no files. Moving the bytes is
the host's job, and this repo shows two ways to do it (below).

Status: works and tested against Bend 2.0.38, including a message captured from
a real printer. Not published anywhere; no package-hub release.

## What Bend 2 is (checked 2026-10-22)

Bend 2 is the successor to the original Bend (a parallel language on the HVM
runtime). It is a Python-shaped, affine, dependently typed language with
proofs ("laws"), compiled to C (CPU, optionally Metal/CUDA GPU) or JS, by a
single `bend` binary. Source: <https://github.com/bendlang/bend>
(`HigherOrderCO/Bend2` and `HigherOrderCO/Bend1` are pointers/archives that say
"moved to github.com/bendlang/bend"). Site: <https://bend-lang.com>.

Install (the official one-liner; `bend update` self-updates):

    curl -fsSL https://bend-lang.com/install.sh | sh
    bend version        # this repo was built and tested with 2.0.38
    bend guide          # the language reference; read it first

Contrary to the common assumption, Bend 2 does have I/O: `File.*`, `TCP.*`,
`UDP.*`, `Process.run`, `IO.args`. It has no DNS (TCP takes an IPv4 literal)
and no TLS. This library still keeps the codec separate from I/O.

## Layout

    src/ipp.bend      the codec (pure; the only file you need)
    src/hostio.bend   optional: read_file / write_file over byte lists
    tests/test_ipp.bend       test suite (TAP-style output, non-zero exit on failure)
    tests/fixtures/           raw bytes captured from a real printer
    examples/make_request.bend    write a Get-Printer-Attributes body to a file
    examples/printer_status.bend  decode a response file, print state + ink
    examples/ipp-status.sh        shell + curl transport
    examples/ipp_status.bend      pure-Bend TCP transport (no shell)

## Run the tests

From the repo root (the fixture paths are relative to it):

    bend tests/test_ipp.bend

Output is one `ok - ...` / `not ok - ...` line per check, then
`all checks passed`, exit status 0. A failing check prints `FAILED` and exits 1.

## Use

```python
import Base
import ./src/ipp.bend as Ipp
import ./src/hostio.bend as H

# bytes are List<&2, U32>, one byte (0..255) per element

def request() -> List<&2, U32>:
  Ipp.get_printer_attributes(
    "ipp://192.168.1.50:631/ipp/print",
    ["marker-levels", "marker-names", "printer-state"],  # [] = printer defaults
    1)                                                    # request-id

# Bend only matches on a parameter, so hand the Result to a helper:
def levels_of(r: Ipp.Res(Ipp.Message)) -> List<&2, U32>:
  match r:
    case Fail{err}:
      []
    case Done{m}:
      Ipp.marker_levels(m)

def levels(resp: List<&2, U32>) -> List<&2, U32>:
  levels_of(Ipp.decode(resp))
```

### API (all in `src/ipp.bend`, used as `Ipp.<name>`)

Types: `Message{major, minor, code, request_id, groups, data}`,
`Group{tag, attrs}`, `Attr{name, values}`, and
`Value = VInt{tag,n} | VBool{b} | VText{tag,s} | VOctets{tag,bytes}`.
`code` is the operation-id of a request or the status-code of a response.

- Encode: `encode(Message) -> Bytes`; `get_printer_attributes(uri, requested, rid)`,
  `print_job(uri, user, job_name, mime, rid, doc)`, `validate_job(uri, user, mime, rid)`;
  attribute builders `Attr.keyword/uri/charset/language/mime/name/text/integer/enum/boolean`.
- Decode: `decode(Bytes) -> Res(Message)`. Fails (never loops or crashes) on a
  truncated header, a truncated name or value, or a missing end-of-attributes tag.
- Read: `values(m, name)` (every value of the first attribute so named, any group),
  `ints`, `texts`, `code`, `request_id`, `data`, `is_success`, `status_name`,
  `printer_state`, `printer_state_name`, `printer_state_reasons`,
  `marker_names/colors/levels`, `markers` (zipped), `level_known`.
- Misc: `utf8.encode/decode`, `hex`.

Value syntaxes: integer/enum (0x21, 0x23) are `VInt`; boolean is `VBool`; every
string-like tag (text, name, keyword, uri, charset, language, mimeMediaType,
memberAttrName) is `VText` decoded as UTF-8; everything else is raw `VOctets`
and round-trips byte for byte.

## Transport

IPP is one HTTP POST: `POST /ipp/print`, `Content-Type: application/ipp`, body =
the encoded message; the 200 response body is the encoded reply. Port 631.
`ipps://` is the same over TLS and is not supported here.

### 1. Shell + curl

    examples/ipp-status.sh 192.168.1.50          # or HOST:PORT

which is just:

    bend examples/make_request.bend ipp://192.168.1.50:631/ipp/print request.bin
    curl -s -H 'Content-Type: application/ipp' --data-binary @request.bin \
         http://192.168.1.50:631/ipp/print -o response.bin
    bend examples/printer_status.bend response.bin

`.local` mDNS names work with curl. To print a document, call `Ipp.print_job`
with the document bytes (read with `H.read_file`), `H.write_file` the result,
and POST it the same way.

### 2. Pure Bend (TCP)

    bend examples/ipp_status.bend 192.168.1.50

builds the request, sends an HTTP/1.0 POST over `TCP.connect`/`TCP.send_bytes`,
reads to EOF, splits off the headers at CRLFCRLF, and decodes. It needs an IPv4
literal (Bend has no DNS) and plain HTTP (no TLS). HTTP/1.0 is used so the
reply is never chunked.

## Fixtures

`tests/fixtures/get-printer-attributes.response.bin` is the unmodified reply of
a Brother MFC-J4335DW (IPP 1.1, `/ipp/print`) captured 2026-10-22 with `curl`
from `get-printer-attributes.request.bin`, the request this library's encoder
produces (a test checks they are byte-identical). Decoded: marker-names
M,C,Y,BK; marker-levels 24,22,16,19; marker-colors #FF00FF,#00FFFF,#FFFF00,
#000000; printer-state idle (3); printer-state-reasons none. The values were
cross-checked against `ipptool -tv ... get-printer-attributes.test` the same
day. The request fixture contains the printer's mDNS hostname.

## Tested vs not

Tested (all passing on Bend 2.0.38, macOS arm64):
- encode reproduces the real captured request byte for byte
- decode of the real captured response; `encode(decode(x)) == x` on it
- exact wire bytes of a tiny hand-checked message
- UTF-8 encode/decode (1 to 4 byte characters, malformed input)
- Print-Job round trip with a non-ASCII job name and trailing document bytes
- -1 integer, boolean, out-of-band, resolution, collection markers, empty
  group, IPP 2.0 version bytes; round trip
- malformed input: empty, short header, truncated name, truncated value,
  missing end tag
- the three examples ran against a real printer (curl path, file path, TCP path)

Not tested / known limits:
- `bend --verdict` (needs Lean 4.34 via elan; not installed). `bend src/ipp.bend`
  prints `ALL PROOFS CHECK`, but note that only means it type-checks and
  terminates: the library states no laws, so nothing about correctness is
  proven. Correctness evidence is the test suite.
- Print-Job and Validate-Job were never sent to a printer (only encoded and
  decoded back); no document was printed.
- Only a Brother MFC-J4335DW was used. Other firmware is untested.
- Collections (`begCollection`/`endCollection`) are surfaced as a flat run of
  values, not a tree. `textWithLanguage`/`nameWithLanguage`, dateTime,
  resolution and rangeOfInteger are raw `VOctets`.
- Integers are `U32`; IPP integers are signed, so -1 reads as 4294967295
  (`level_known` handles the marker case).
- No HTTP client beyond the toy HTTP/1.0 example, no TLS, no auth, no chunked
  encoding, no IPP-over-USB, no operations beyond the three above (but
  `encode`/`Message` build any operation).
- Performance is untuned: byte lists, quadratic appends in places. Fine for
  status queries; do not use it to move large documents through `encode`
  (it works, but copy the document bytes in at the end as `Message.data`).
- Written against Bend 2.0.38. Bend 2 is young and its syntax changes; expect
  to adjust for later versions.

## Notes for contributors (Bend gotchas hit while writing this)

- `match` only takes a def parameter, never a computed value or a local, and a
  Bool test is a helper whose Bool is the FIRST parameter (scrutinees are matched
  in binder order). Hence the many tiny `.if` helpers.
- No mutual recursion: loops are single defs with a shrinking `Nat` fuel (or
  list) first; branching is done by computing the next state as an argument.
- `A & B` is not `Data`; use a `Data` pair type (`Pr`) when you need to copy.
- Anything used twice needs `+`.

## Prior art

Searched 2026-10-22 (GitHub repo and code search, web search) for an IPP library
in Bend 2 or Bend 1 and found none: no repository, package or snippet
implementing IPP in either. Bend-language hits for "ipp" were unrelated. (Code search for
`.bend` files turned up only unrelated socket/runtime code.) IPP libraries in other languages, for reference:
[OpenPrinting CUPS](https://github.com/OpenPrinting/cups) (C, `ipptool`),
[ippsample](https://github.com/istopwg/ippsample), Chromium OS `libipp` (C++),
[go-ipp](https://github.com/phin1x/go-ipp),
[jipp](https://github.com/HPInc/jipp), [pkipplib](https://pypi.org/project/pkipplib/)
(Python), [ipp](https://github.com/williamkapke/ipp) (Node).

## References

- RFC 8010, IPP/1.1: Encoding and Transport: <https://www.rfc-editor.org/rfc/rfc8010>
- RFC 8011, IPP/1.1: Model and Semantics: <https://www.rfc-editor.org/rfc/rfc8011>

## License

MIT, see `LICENSE`.
