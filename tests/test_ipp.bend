# SPDX-License-Identifier: MIT
#
# bend-ipp test suite. Run from the repository root (fixture paths are
# relative to it):
#
#   bend tests/test_ipp.bend
#
# Prints one TAP-style line per check and exits non-zero if any check fails.
import Base
import ../src/ipp.bend as Ipp
import ../src/hostio.bend as H

type T is Data:
  T{name: String, ok: Bool}

def bytes_eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{a, at} Con{b, bt}:
      Bool.and(U32.is_eq(a, b), bytes_eq(at, bt))
    case _ _:
      False{}

def strs_eq(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{a, at} Con{b, bt}:
      Bool.and(String.eq(a, b), strs_eq(at, bt))
    case _ _:
      False{}

def fails(r: Ipp.Res(Ipp.Message)) -> Bool:
  match r:
    case Fail{e}:
      True{}
    case Done{m}:
      False{}

# ---- checks on the real printer response ---------------------------------

def check_response(+m: Ipp.Message, req: List<&2, U32>, resp: List<&2, U32>) -> List<&2, T>:
  T{"fixture: status is successful-ok", Ipp.is_success(m)}
  <> T{"fixture: request-id echoes 1", U32.is_eq(Ipp.request_id(m), 1)}
  <> T{"fixture: marker-levels are 24,22,16,19", bytes_eq(Ipp.marker_levels(m), [24, 22, 16, 19])}
  <> T{"fixture: marker-names are M,C,Y,BK", strs_eq(Ipp.marker_names(m), ["M", "C", "Y", "BK"])}
  <> T{"fixture: marker-colors are hex strings", strs_eq(Ipp.marker_colors(m), ["#FF00FF", "#00FFFF", "#FFFF00", "#000000"])}
  <> T{"fixture: printer-state is idle (3)", String.eq(Ipp.printer_state_name(m), "idle")}
  <> T{"fixture: printer-state-reasons is none", strs_eq(Ipp.printer_state_reasons(m), ["none"])}
  <> T{"fixture: markers zip to 4 entries", Nat.is_eq(List.length(&2, Ipp.Marker, Ipp.markers(m)), 4n)}
  <> T{"fixture: 2 attribute groups (operation, printer)", Nat.is_eq(Ipp.group_count(m), 2n)}
  <> T{"fixture: encode(decode(x)) == x", bytes_eq(Ipp.encode(m), resp)}
  <> []

def check_response_r(r: Ipp.Res(Ipp.Message), req: List<&2, U32>, resp: List<&2, U32>) -> List<&2, T>:
  match r:
    case Fail{e}:
      [T{"fixture: response decodes: " ++ e, False{}}]
    case Done{+m}:
      check_response(m, req, resp)

# ---- the request we send is the request that was captured ------------------

def check_request(req: List<&2, U32>) -> List<&2, T>:
  T{"request: encoder reproduces the captured request bytes", bytes_eq(Ipp.get_printer_attributes("ipp://BRW000000000000.local:631/ipp/print", ["marker-names", "marker-levels", "marker-colors", "printer-state", "printer-state-reasons"], 1), req)}
  <> []

def check_request_dec(r: Ipp.Res(Ipp.Message)) -> List<&2, T>:
  match r:
    case Fail{e}:
      [T{"request fixture decodes: " ++ e, False{}}]
    case Done{+m}:
      [T{"request fixture: operation is Get-Printer-Attributes (0x000B)", U32.is_eq(Ipp.code(m), 11)},
       T{"request fixture: printer-uri decodes", strs_eq(Ipp.texts(Ipp.values(m, "printer-uri")), ["ipp://BRW000000000000.local:631/ipp/print"])},
       T{"request fixture: 5 requested-attributes (1setOf)", Nat.is_eq(List.length(&2, String, Ipp.texts(Ipp.values(m, "requested-attributes"))), 5n)}]

# ---- exact wire bytes for a tiny message ---------------------------------

def tiny() -> Ipp.Message:
  Ipp.Message{1, 1, 11, 1, [Ipp.Group{1, [Ipp.Attr.charset("attributes-charset", "utf-8")]}], []}

def check_tiny() -> List<&2, T>:
  [T{"tiny: exact wire bytes", bytes_eq(Ipp.encode(tiny()), [1, 1, 0, 11, 0, 0, 0, 1, 1, 71, 0, 18, 97, 116, 116, 114, 105, 98, 117, 116, 101, 115, 45, 99, 104, 97, 114, 115, 101, 116, 0, 5, 117, 116, 102, 45, 56, 3])},
   T{"tiny: hex()", String.eq(Ipp.hex([0, 15, 16, 171, 255]), "000f10abff")}]

# ---- UTF-8 ---------------------------------------------------------------

def check_utf8() -> List<&2, T>:
  [T{"utf8: 2-byte (e acute) is C3 A9", bytes_eq(Ipp.utf8.encode("é"), [195, 169])},
   T{"utf8: round trip 1-4 byte characters", String.eq(Ipp.utf8.decode(Ipp.utf8.encode("aé€😀")), "aé€😀")},
   T{"utf8: malformed byte becomes U+FFFD", String.eq(Ipp.utf8.decode([97, 255, 98]), "a�b")}]

# ---- Print-Job -----------------------------------------------------------

def check_print_job_r(r: Ipp.Res(Ipp.Message)) -> List<&2, T>:
  match r:
    case Fail{e}:
      [T{"print-job decodes: " ++ e, False{}}]
    case Done{+m}:
      [T{"print-job: operation is 0x0002", U32.is_eq(Ipp.code(m), 2)},
       T{"print-job: request-id 7", U32.is_eq(Ipp.request_id(m), 7)},
       T{"print-job: document bytes follow end-of-attributes", bytes_eq(Ipp.data(m), [37, 80, 68, 70, 3, 3])},
       T{"print-job: job-name survives UTF-8", strs_eq(Ipp.texts(Ipp.values(m, "job-name")), ["café"])},
       T{"print-job: document-format", strs_eq(Ipp.texts(Ipp.values(m, "document-format")), ["application/pdf"])}]

def print_job_bytes() -> List<&2, U32>:
  Ipp.print_job("ipp://printer.local:631/ipp/print", "david", "café", "application/pdf", 7, [37, 80, 68, 70, 3, 3])

# ---- integers, booleans, collections, out-of-band ------------------------

def exotic() -> Ipp.Message:
  Ipp.Message{2, 0, 0, 99, [Ipp.Group{4, [
    Ipp.Attr.integer("n", 4294967295),
    Ipp.Attr.boolean("b", True{}),
    Ipp.Attr{"media-col", [Ipp.VOctets{52, []}, Ipp.VText{74, "media-size"}, Ipp.VInt{33, 5}, Ipp.VOctets{55, []}]},
    Ipp.Attr{"oob", [Ipp.VOctets{19, []}]},
    Ipp.Attr{"res", [Ipp.VOctets{50, [0, 0, 1, 44, 0, 0, 1, 44, 3]}]}]},
    Ipp.Group{2, []}], []}

def check_exotic_r(r: Ipp.Res(Ipp.Message), want: List<&2, U32>) -> List<&2, T>:
  match r:
    case Fail{e}:
      [T{"exotic decodes: " ++ e, False{}}]
    case Done{+m}:
      [T{"exotic: encode(decode(x)) == x", bytes_eq(Ipp.encode(m), want)},
       T{"exotic: collection stays a flat run of 4 values", Nat.is_eq(List.length(&2, Ipp.Value, Ipp.values(m, "media-col")), 4n)},
       T{"exotic: version 2.0 kept", Bool.and(U32.is_eq(Ipp.version_major(m), 2), U32.is_eq(Ipp.version_minor(m), 0))},
       T{"exotic: -1 integer is 0xFFFFFFFF", bytes_eq(Ipp.ints(Ipp.values(m, "n")), [4294967295])},
       T{"exotic: empty trailing group kept", Nat.is_eq(Ipp.group_count(m), 2n)}]

# ---- malformed input -----------------------------------------------------

def check_bad(+resp: List<&2, U32>) -> List<&2, T>:
  [T{"bad: empty input fails", fails(Ipp.decode([]))},
   T{"bad: short header fails", fails(Ipp.decode([1, 1, 0]))},
   T{"bad: truncated in a name fails", fails(Ipp.decode(List.take(&2, U32, resp, 20n)))},
   T{"bad: truncated in a value fails", fails(Ipp.decode(List.take(&2, U32, resp, 100n)))},
   T{"bad: missing end-of-attributes fails", fails(Ipp.decode([1, 1, 0, 0, 0, 0, 0, 1, 1]))}]

# ---- driver ---------------------------------------------------------------

def count_bad(ts: List<&2, T>) -> U32:
  match ts:
    case Nil{}:
      0
    case Con{T{name, ok}, rest}:
      U32.add(Bool.to_u32(Bool.not(ok)), count_bad(rest))

def line(t: T) -> String:
  match t:
    case T{name, ok}:
      Bool.pick(String, ok, "ok - ", "not ok - ") ++ name

def report(ts: List<&2, T>) -> IO(Unit):
  match ts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{t, rest}:
      do IO<Unit>:
        u : Unit <- IO.print(line(t))
        report(rest)

def finish(bad: Bool) -> IO(Unit):
  match bad:
    case True{}:
      do IO<Unit>:
        u : Unit <- IO.print("FAILED")
        IO.exit(1)
    case False{}:
      IO.print("all checks passed")

def run(+req: List<&2, U32>, +resp: List<&2, U32>) -> IO(Unit):
  +ts = List.concat(&2, T, [
    check_request(req),
    check_request_dec(Ipp.decode(req)),
    check_response_r(Ipp.decode(resp), req, resp),
    check_tiny(),
    check_utf8(),
    check_print_job_r(Ipp.decode(print_job_bytes())),
    check_exotic_r(Ipp.decode(Ipp.encode(exotic())), Ipp.encode(exotic())),
    check_bad(resp)])
  do IO<Unit>:
    u : Unit <- report(ts)
    finish(U32.is_ne(count_bad(ts), 0))

def main() -> IO(Unit):
  do IO<Unit>:
    req : List<&2, U32> <- H.read_file("tests/fixtures/get-printer-attributes.request.bin")
    resp : List<&2, U32> <- H.read_file("tests/fixtures/get-printer-attributes.response.bin")
    run(req, resp)
