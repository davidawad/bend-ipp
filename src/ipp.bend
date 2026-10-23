# SPDX-License-Identifier: MIT
#
# bend-ipp: a pure encode/decode layer for the Internet Printing Protocol
# (RFC 8010 binary encoding, RFC 8011 operations) in Bend 2.
#
# Everything here is a pure function over byte lists (List<&2, U32>, one byte
# per element, each in 0..255). Moving bytes over HTTP is the host's job; see
# README.md.
import Base

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

# A byte string: one U32 in 0..255 per element.
def Bytes() -> Data:
  List<&2, U32>

# A Data-kinded pair (Base's `A & B` is not Data).
type Pr<-A: Data, -B: Data> is Data:
  Pr{fst: A, snd: B}

# Result with a String error, reusable (Data).
def Res(-A: Data) -> Data:
  Result<&2, &2, String, A>

# One attribute value. `tag` is the RFC 8010 value-tag byte.
#   VInt    integer (0x21) and enum (0x23), 4 bytes big-endian
#   VBool   boolean (0x22)
#   VText   every string-like syntax: textWithoutLanguage 0x41,
#           nameWithoutLanguage 0x42, keyword 0x44, uri 0x45, uriScheme 0x46,
#           charset 0x47, naturalLanguage 0x48, mimeMediaType 0x49,
#           memberAttrName 0x4A (UTF-8)
#   VOctets anything else, raw: dateTime 0x31, resolution 0x32,
#           rangeOfInteger 0x33, begCollection 0x34 / endCollection 0x37
#           (collections surface as a flat run of values), out-of-band
#           0x10-0x13, textWithLanguage 0x35, nameWithLanguage 0x36, ...
type Value is Data:
  VInt{tag: U32, n: U32}
  VBool{b: Bool}
  VText{tag: U32, s: String}
  VOctets{tag: U32, bytes: List<&2, U32>}

# A named attribute with one or more values (1setOf).
type Attr is Data:
  Attr{name: String, values: List<&2, Value>}

# An attribute group; `tag` is the delimiter byte (1 operation, 2 job,
# 4 printer, 5 unsupported, ...).
type Group is Data:
  Group{tag: U32, attrs: List<&2, Attr>}

# A whole IPP message (request or response). `code` is the operation-id of a
# request or the status-code of a response. `data` is whatever follows the
# end-of-attributes tag (the document, for Print-Job).
type Message is Data:
  Message{major: U32, minor: U32, code: U32, request_id: U32, groups: List<&2, Group>, data: List<&2, U32>}

# ---------------------------------------------------------------------------
# Constants (RFC 8010 / 8011)
# ---------------------------------------------------------------------------

def Op.print_job() -> U32:
  2

def Op.validate_job() -> U32:
  4

def Op.get_printer_attributes() -> U32:
  11

def Tag.operation_group() -> U32:
  1

def Tag.printer_group() -> U32:
  4

def Tag.end_of_attributes() -> U32:
  3

def Tag.integer() -> U32:
  33

def Tag.boolean() -> U32:
  34

def Tag.enum() -> U32:
  35

def Tag.text() -> U32:
  65

def Tag.name() -> U32:
  66

def Tag.keyword() -> U32:
  68

def Tag.uri() -> U32:
  69

def Tag.charset() -> U32:
  71

def Tag.language() -> U32:
  72

def Tag.mime() -> U32:
  73

# printer-state enum (RFC 8011 5.4.11)
def State.name(n: U32) -> String:
  match n:
    case 3:
      "idle"
    case 4:
      "processing"
    case 5:
      "stopped"
    case _:
      "unknown"

# ---------------------------------------------------------------------------
# Byte helpers
# ---------------------------------------------------------------------------

def cat(xs: Bytes(), ys: Bytes()) -> Bytes():
  List.append(&2, U32, xs, ys)

def len32(+bs: Bytes()) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

def u16(+n: U32) -> Bytes():
  [U32.and(U32.shrn(n, 8n), 255), U32.and(n, 255)]

def u32(+n: U32) -> Bytes():
  [U32.and(U32.shrn(n, 24n), 255), U32.and(U32.shrn(n, 16n), 255), U32.and(U32.shrn(n, 8n), 255), U32.and(n, 255)]

# UTF-8 encode one code point.
def utf8.enc4(+cp: U32) -> Bytes():
  [U32.or(240, U32.shrn(cp, 18n)), U32.or(128, U32.and(U32.shrn(cp, 12n), 63)), U32.or(128, U32.and(U32.shrn(cp, 6n), 63)), U32.or(128, U32.and(cp, 63))]

def utf8.enc3(+cp: U32) -> Bytes():
  [U32.or(224, U32.shrn(cp, 12n)), U32.or(128, U32.and(U32.shrn(cp, 6n), 63)), U32.or(128, U32.and(cp, 63))]

def utf8.enc2(+cp: U32) -> Bytes():
  [U32.or(192, U32.shrn(cp, 6n)), U32.or(128, U32.and(cp, 63))]

def utf8.enc.if3(+cp: U32, small: Bool) -> Bytes():
  match small:
    case True{}:
      utf8.enc3(cp)
    case False{}:
      utf8.enc4(cp)

def utf8.enc.if2(+cp: U32, small: Bool) -> Bytes():
  match small:
    case True{}:
      utf8.enc2(cp)
    case False{}:
      utf8.enc.if3(cp, U32.is_lt(cp, 65536))

def utf8.enc.if1(+cp: U32, ascii: Bool) -> Bytes():
  match ascii:
    case True{}:
      [cp]
    case False{}:
      utf8.enc.if2(cp, U32.is_lt(cp, 2048))

# String -> UTF-8 bytes.
def utf8.encode(s: String) -> Bytes():
  match s:
    case SNil{}:
      []
    case SCon{h, t}:
      +cp = Char.to_u32(h)
      cat(utf8.enc.if1(cp, U32.is_lt(cp, 128)), utf8.encode(t))


# ---------------------------------------------------------------------------
# UTF-8 decoding
# ---------------------------------------------------------------------------
#
# Bend only allows `match` on a def parameter (never on a computed value) and
# forbids mutual recursion, so the decoders below are written as: a total,
# non-recursive "step" helper that returns data, plus one structurally
# recursive loop that threads the helper's output through its arguments.
# Boolean tests are helpers that take their Bool as the FIRST parameter.

def pfst(-A: Data, -B: Data, p: Pr<A, B>) -> A:
  match p:
    case Pr{a, b}:
      a

def psnd(-A: Data, -B: Data, p: Pr<A, B>) -> B:
  match p:
    case Pr{a, b}:
      b

def utf8.bad(rest: Bytes()) -> Pr<Char, Bytes()>:
  Pr{Char.from_u32(65533), rest}

def utf8.one4(four: Bool, +b0: U32, rest: Bytes()) -> Pr<Char, Bytes()>:
  match four:
    case True{}:
      match rest:
        case Con{b1, Con{b2, Con{b3, r4}}}:
          Pr{Char.from_u32(U32.or(U32.or(U32.shln(U32.and(b0, 7), 18n), U32.shln(U32.and(b1, 63), 12n)), U32.or(U32.shln(U32.and(b2, 63), 6n), U32.and(b3, 63)))), r4}
        case _:
          utf8.bad([])
    case False{}:
      utf8.bad(rest)

def utf8.one3(three: Bool, +b0: U32, rest: Bytes()) -> Pr<Char, Bytes()>:
  match three:
    case True{}:
      match rest:
        case Con{b1, Con{b2, r3}}:
          Pr{Char.from_u32(U32.or(U32.or(U32.shln(U32.and(b0, 15), 12n), U32.shln(U32.and(b1, 63), 6n)), U32.and(b2, 63))), r3}
        case _:
          utf8.bad([])
    case False{}:
      utf8.one4(U32.is_eq(U32.and(b0, 248), 240), b0, rest)

def utf8.one2(two: Bool, +b0: U32, rest: Bytes()) -> Pr<Char, Bytes()>:
  match two:
    case True{}:
      match rest:
        case Con{b1, r2}:
          Pr{Char.from_u32(U32.or(U32.shln(U32.and(b0, 31), 6n), U32.and(b1, 63))), r2}
        case _:
          utf8.bad([])
    case False{}:
      utf8.one3(U32.is_eq(U32.and(b0, 240), 224), b0, rest)

def utf8.one1(ascii: Bool, +b0: U32, rest: Bytes()) -> Pr<Char, Bytes()>:
  match ascii:
    case True{}:
      Pr{Char.from_u32(b0), rest}
    case False{}:
      utf8.one2(U32.is_eq(U32.and(b0, 224), 192), b0, rest)

# Decode one character from lead byte b0 and the bytes after it.
def utf8.one(+b0: U32, rest: Bytes()) -> Pr<Char, Bytes()>:
  utf8.one1(U32.is_lt(b0, 128), b0, rest)

def utf8.decode.go(fuel: Nat, bs: Bytes(), acc: List<&2, Char>) -> String:
  match fuel:
    case 0n:
      String.from_list(List.reverse(&2, Char, acc))
    case 1n+p:
      match bs:
        case Nil{}:
          String.from_list(List.reverse(&2, Char, acc))
        case Con{b0, rest}:
          +s = utf8.one(b0, rest)
          utf8.decode.go(p, psnd(Char, Bytes(), s), pfst(Char, Bytes(), s) <> acc)

# UTF-8 bytes -> String. Malformed input yields U+FFFD; never fails.
def utf8.decode(+bs: Bytes()) -> String:
  utf8.decode.go(List.length(&2, U32, bs), bs, [])

# ---------------------------------------------------------------------------
# Decoding (RFC 8010 section 3)
# ---------------------------------------------------------------------------

# Flat lexical items, in wire order.
type Item is Data:
  IGroup{tag: U32}
  IAttr{name: String, value: Value}
  IBad{msg: String}

type Mode is Data:
  MTag{}
  MEnd{}

# What one tag (and, for a value tag, its whole entry) contributes.
type Step is Data:
  Step{items: List<&2, Item>, rest: List<&2, U32>, end: Bool}

type Parsed is Data:
  Parsed{items_rev: List<&2, Item>, data: List<&2, U32>, ended: Bool}

def Step.bad(msg: String) -> Step:
  Step{[IBad{msg}], [], False{}}

def Step.items(s: Step) -> List<&2, Item>:
  match s:
    case Step{items, rest, end}:
      items

def Step.rest(s: Step) -> Bytes():
  match s:
    case Step{items, rest, end}:
      rest

def Step.mode.of(end: Bool) -> Mode:
  match end:
    case True{}:
      MEnd{}
    case False{}:
      MTag{}

def Step.mode(s: Step) -> Mode:
  match s:
    case Step{items, rest, end}:
      Step.mode.of(end)

# Take exactly n bytes: (prefix, remainder), or Fail if too short.
def take.go(n: Nat, +bs: Bytes(), acc: Bytes()) -> Res(Pr<Bytes(), Bytes()>):
  match n:
    case 0n:
      Done{Pr{List.reverse(&2, U32, acc), bs}}
    case 1n+p:
      match bs:
        case Nil{}:
          Fail{"truncated message"}
        case Con{h, t}:
          take.go(p, t, h <> acc)

def take(n: U32, bs: Bytes()) -> Res(Pr<Bytes(), Bytes()>):
  take.go(U32.to_nat(n), bs, [])

def be16(+a: U32, +b: U32) -> U32:
  (a * 256 + b : U32)

def be32(+a: U32, +b: U32, +c: U32, +d: U32) -> U32:
  U32.or(U32.or(U32.shln(a, 24n), U32.shln(b, 16n)), U32.or(U32.shln(c, 8n), d))

def dv.int(t: U32, +vb: Bytes()) -> Value:
  match vb:
    case Con{a, Con{b, Con{c, Con{d, Nil{}}}}}:
      VInt{t, be32(a, b, c, d)}
    case _:
      VOctets{t, vb}

def dv.bool(t: U32, +vb: Bytes()) -> Value:
  match vb:
    case Con{x, Nil{}}:
      VBool{U32.is_ne(x, 0)}
    case _:
      VOctets{t, vb}

def dv.text(t: U32, vb: Bytes()) -> Value:
  VText{t, utf8.decode(vb)}

# Interpret value bytes according to the value-tag.
def decode_value(t: U32, vb: Bytes()) -> Value:
  match t:
    case 33:
      dv.int(t, vb)
    case 35:
      dv.int(t, vb)
    case 34:
      dv.bool(t, vb)
    case 65:
      dv.text(t, vb)
    case 66:
      dv.text(t, vb)
    case 68:
      dv.text(t, vb)
    case 69:
      dv.text(t, vb)
    case 70:
      dv.text(t, vb)
    case 71:
      dv.text(t, vb)
    case 72:
      dv.text(t, vb)
    case 73:
      dv.text(t, vb)
    case 74:
      dv.text(t, vb)
    case _:
      VOctets{t, vb}

def entry.value(t: U32, +name: Bytes(), taken: Res(Pr<Bytes(), Bytes()>)) -> Step:
  match taken:
    case Fail{e}:
      Step.bad(e)
    case Done{Pr{vb, rest}}:
      Step{[IAttr{utf8.decode(name), decode_value(t, vb)}], rest, False{}}

def entry.vlen(t: U32, +name: Bytes(), r: Bytes()) -> Step:
  match r:
    case Con{v1, Con{v2, r2}}:
      entry.value(t, name, take(be16(v1, v2), r2))
    case _:
      Step.bad("truncated message (value length)")

def entry.name(t: U32, taken: Res(Pr<Bytes(), Bytes()>)) -> Step:
  match taken:
    case Fail{e}:
      Step.bad(e)
    case Done{Pr{name, r}}:
      entry.vlen(t, name, r)

# One attribute entry; `bs` starts right after the value-tag byte.
def entry(t: U32, bs: Bytes()) -> Step:
  match bs:
    case Con{n1, Con{n2, r}}:
      entry.name(t, take(be16(n1, n2), r))
    case _:
      Step.bad("truncated message (name length)")

def tag_step.grp(g: Bool, t: U32, rest: Bytes()) -> Step:
  match g:
    case True{}:
      Step{[IGroup{t}], rest, False{}}
    case False{}:
      entry(t, rest)

def tag_step.end(e: Bool, +t: U32, rest: Bytes()) -> Step:
  match e:
    case True{}:
      Step{[], rest, True{}}
    case False{}:
      tag_step.grp(U32.is_lt(t, 16), t, rest)

def tag_step(+t: U32, rest: Bytes()) -> Step:
  tag_step.end(U32.is_eq(t, 3), t, rest)

# The lexer loop. Every MTag iteration consumes at least one byte, so a fuel of
# length+2 is always enough.
def lex(fuel: Nat, mode: Mode, bs: Bytes(), acc: List<&2, Item>) -> Parsed:
  match fuel:
    case 0n:
      Parsed{acc, bs, False{}}
    case 1n+p:
      match mode:
        case MEnd{}:
          Parsed{acc, bs, True{}}
        case MTag{}:
          match bs:
            case Nil{}:
              Parsed{acc, [], False{}}
            case Con{t, rest}:
              +s = tag_step(t, rest)
              lex(p, Step.mode(s), Step.rest(s), List.append(&2, Item, Step.items(s), acc))

# Fold flat items into groups.
type Acc is Data:
  Acc{done: List<&2, Group>, open: Bool, tag: U32, attrs: List<&2, Attr>}

def Acc.flush.if(open: Bool, done: List<&2, Group>, tag: U32, attrs: List<&2, Attr>) -> List<&2, Group>:
  match open:
    case True{}:
      Group{tag, List.reverse(&2, Attr, attrs)} <> done
    case False{}:
      done

def Acc.flush(acc: Acc) -> List<&2, Group>:
  match acc:
    case Acc{done, open, tag, attrs}:
      Acc.flush.if(open, done, tag, attrs)

def Acc.group(acc: Acc, t: U32) -> Acc:
  Acc{Acc.flush(acc), True{}, t, []}

def Acc.more(attrs: List<&2, Attr>, value: Value) -> List<&2, Attr>:
  match attrs:
    case Nil{}:
      [Attr{"", [value]}]
    case Con{Attr{n, vs}, rest}:
      Attr{n, List.append(&2, Value, vs, [value])} <> rest

def Acc.add.if(empty: Bool, done: List<&2, Group>, tag: U32, attrs: List<&2, Attr>, name: String, value: Value) -> Acc:
  match empty:
    case True{}:
      Acc{done, True{}, tag, Acc.more(attrs, value)}
    case False{}:
      Acc{done, True{}, tag, Attr{name, [value]} <> attrs}

def Acc.add(acc: Acc, +name: String, value: Value) -> Acc:
  match acc:
    case Acc{done, open, tag, attrs}:
      Acc.add.if(String.is_empty(name), done, tag, attrs, name, value)

def groups.go(items: List<&2, Item>, acc: Acc) -> List<&2, Group>:
  match items:
    case Nil{}:
      List.reverse(&2, Group, Acc.flush(acc))
    case Con{it, rest}:
      match it:
        case IGroup{t}:
          groups.go(rest, Acc.group(acc, t))
        case IAttr{name, value}:
          groups.go(rest, Acc.add(acc, name, value))
        case IBad{m}:
          groups.go(rest, acc)

def first_bad(items: List<&2, Item>) -> Maybe<&2, String>:
  match items:
    case Nil{}:
      None{}
    case Con{IBad{m}, rest}:
      Some{m}
    case Con{_, rest}:
      first_bad(rest)

def decode.fin2(ended: Bool, hdr: Message, items_rev: List<&2, Item>, data: Bytes()) -> Res(Message):
  match ended:
    case False{}:
      Fail{"missing end-of-attributes tag"}
    case True{}:
      match hdr:
        case Message{maj, min, code, rid, gs, d}:
          Done{Message{maj, min, code, rid, groups.go(List.reverse(&2, Item, items_rev), Acc{[], False{}, 0, []}), data}}

def decode.fin1(bad: Maybe<&2, String>, ended: Bool, hdr: Message, items_rev: List<&2, Item>, data: Bytes()) -> Res(Message):
  match bad:
    case Some{e}:
      Fail{e}
    case None{}:
      decode.fin2(ended, hdr, items_rev, data)

def decode.fin(hdr: Message, p: Parsed) -> Res(Message):
  match p:
    case Parsed{+items_rev, data, ended}:
      decode.fin1(first_bad(items_rev), ended, hdr, items_rev, data)

def decode.body(hdr: Message, +rest: Bytes()) -> Res(Message):
  decode.fin(hdr, lex(Nat.add(List.length(&2, U32, rest), 2n), MTag{}, rest, []))

# Decode a complete IPP message (request or response) from its bytes.
def decode(bs: Bytes()) -> Res(Message):
  match bs:
    case Con{maj, Con{min, Con{c1, Con{c2, Con{r1, Con{r2, Con{r3, Con{r4, rest}}}}}}}}:
      decode.body(Message{maj, min, be16(c1, c2), be32(r1, r2, r3, r4), [], []}, rest)
    case _:
      Fail{"truncated message (header)"}

# ---------------------------------------------------------------------------
# Accessors for decoded messages
# ---------------------------------------------------------------------------

def pick(hit: Bool, a: List<&2, Value>, b: List<&2, Value>) -> List<&2, Value>:
  match hit:
    case True{}:
      a
    case False{}:
      b

def first_nonempty(a: List<&2, Value>, b: List<&2, Value>) -> List<&2, Value>:
  match a:
    case Nil{}:
      b
    case Con{h, t}:
      h <> t

def values_in_attrs(+name: String, attrs: List<&2, Attr>) -> List<&2, Value>:
  match attrs:
    case Nil{}:
      []
    case Con{Attr{n, vs}, rest}:
      pick(String.eq(n, name), vs, values_in_attrs(name, rest))

def values_in_groups(+name: String, gs: List<&2, Group>) -> List<&2, Value>:
  match gs:
    case Nil{}:
      []
    case Con{Group{tag, attrs}, rest}:
      first_nonempty(values_in_attrs(name, attrs), values_in_groups(name, rest))

# All values of the first attribute called `name`, searching every group in
# order. Empty list when absent.
def values(m: Message, +name: String) -> List<&2, Value>:
  match m:
    case Message{maj, min, code, rid, gs, d}:
      values_in_groups(name, gs)

def ints(vs: List<&2, Value>) -> List<&2, U32>:
  match vs:
    case Nil{}:
      []
    case Con{VInt{t, n}, rest}:
      n <> ints(rest)
    case Con{_, rest}:
      ints(rest)

def texts(vs: List<&2, Value>) -> List<&2, String>:
  match vs:
    case Nil{}:
      []
    case Con{VText{t, s}, rest}:
      s <> texts(rest)
    case Con{_, rest}:
      texts(rest)

def first_int(vs: List<&2, Value>) -> Maybe<&2, U32>:
  List.head(&2, U32, ints(vs))

# The operation-id (request) or status-code (response).
def code(m: Message) -> U32:
  match m:
    case Message{maj, min, c, rid, gs, d}:
      c

def request_id(m: Message) -> U32:
  match m:
    case Message{maj, min, c, rid, gs, d}:
      rid

# The bytes after end-of-attributes (the document for Print-Job).
def data(m: Message) -> Bytes():
  match m:
    case Message{maj, min, c, rid, gs, d}:
      d

# Status codes 0x0000-0x00FF are successful (RFC 8011 section 5.4.15).
def is_success(m: Message) -> Bool:
  U32.is_lt(code(m), 256)

def status_name(c: U32) -> String:
  match c:
    case 0:
      "successful-ok"
    case 1:
      "successful-ok-ignored-or-substituted-attributes"
    case 2:
      "successful-ok-conflicting-attributes"
    case 1024:
      "client-error-bad-request"
    case 1025:
      "client-error-forbidden"
    case 1026:
      "client-error-not-authenticated"
    case 1027:
      "client-error-not-authorized"
    case 1028:
      "client-error-not-possible"
    case 1029:
      "client-error-timeout"
    case 1030:
      "client-error-not-found"
    case 1034:
      "client-error-request-value-too-long"
    case 1035:
      "client-error-document-format-not-supported"
    case 1036:
      "client-error-attributes-or-values-not-supported"
    case 1280:
      "server-error-internal-error"
    case 1281:
      "server-error-operation-not-supported"
    case 1282:
      "server-error-service-unavailable"
    case 1283:
      "server-error-version-not-supported"
    case 1284:
      "server-error-device-error"
    case 1285:
      "server-error-temporary-error"
    case 1286:
      "server-error-not-accepting-jobs"
    case 1287:
      "server-error-busy"
    case _:
      "unknown-status"

# printer-state (enum 3 idle, 4 processing, 5 stopped).
def printer_state(m: Message) -> Maybe<&2, U32>:
  first_int(values(m, "printer-state"))

def printer_state_reasons(m: Message) -> List<&2, String>:
  texts(values(m, "printer-state-reasons"))

def marker_levels(m: Message) -> List<&2, U32>:
  ints(values(m, "marker-levels"))

def marker_names(m: Message) -> List<&2, String>:
  texts(values(m, "marker-names"))

def marker_colors(m: Message) -> List<&2, String>:
  texts(values(m, "marker-colors"))

# One consumable. `level` is a percentage 0-100, or a negative IPP integer
# (-1 other, -2 unknown, -3 at-least-one-remains) which shows up here as the
# two's-complement U32 (4294967295 for -1); use `level_known` to test.
type Marker is Data:
  Marker{name: String, color: String, level: U32}

def level_known(level: U32) -> Bool:
  U32.is_le(level, 100)

def markers.go(names: List<&2, String>, colors: List<&2, String>, levels: List<&2, U32>) -> List<&2, Marker>:
  match names colors levels:
    case Con{n, nt} Con{c, ct} Con{l, lt}:
      Marker{n, c, l} <> markers.go(nt, ct, lt)
    case _ _ _:
      []

# marker-names, marker-colors and marker-levels zipped.
def markers(+m: Message) -> List<&2, Marker>:
  markers.go(marker_names(m), marker_colors(m), marker_levels(m))

def State.name_of(o: Maybe<&2, U32>) -> String:
  match o:
    case None{}:
      "unknown"
    case Some{n}:
      State.name(n)

# "idle", "processing", "stopped", or "unknown" (also when absent).
def printer_state_name(m: Message) -> String:
  State.name_of(printer_state(m))

def version_major(m: Message) -> U32:
  match m:
    case Message{maj, min, c, rid, gs, d}:
      maj

def version_minor(m: Message) -> U32:
  match m:
    case Message{maj, min, c, rid, gs, d}:
      min

def group_count(m: Message) -> Nat:
  match m:
    case Message{maj, min, c, rid, gs, d}:
      List.length(&2, Group, gs)

# ---------------------------------------------------------------------------
# Encoding (RFC 8010 section 3)
# ---------------------------------------------------------------------------

def entry_bytes(tag: U32, +name: String, +vb: Bytes()) -> Bytes():
  +nb = utf8.encode(name)
  cat([tag], cat(u16(len32(nb)), cat(nb, cat(u16(len32(vb)), vb))))

def value_tag(v: Value) -> U32:
  match v:
    case VInt{tag, n}:
      tag
    case VBool{b}:
      34
    case VText{tag, s}:
      tag
    case VOctets{tag, bs}:
      tag

def value_bytes(v: Value) -> Bytes():
  match v:
    case VInt{tag, n}:
      u32(n)
    case VBool{b}:
      [Bool.to_u32(b)]
    case VText{tag, s}:
      utf8.encode(s)
    case VOctets{tag, bs}:
      bs

# A 1setOf attribute: the first value carries the name, the rest an empty name.
def encode_values(vs: List<&2, Value>, +name: String) -> Bytes():
  match vs:
    case Nil{}:
      []
    case Con{+v, rest}:
      cat(entry_bytes(value_tag(v), name, value_bytes(v)), encode_values(rest, ""))

def encode_attrs(attrs: List<&2, Attr>) -> Bytes():
  match attrs:
    case Nil{}:
      []
    case Con{Attr{name, vs}, rest}:
      cat(encode_values(vs, name), encode_attrs(rest))

def encode_groups(gs: List<&2, Group>) -> Bytes():
  match gs:
    case Nil{}:
      []
    case Con{Group{tag, attrs}, rest}:
      cat([tag], cat(encode_attrs(attrs), encode_groups(rest)))

# Encode a Message to its wire bytes.
def encode(m: Message) -> Bytes():
  match m:
    case Message{maj, min, c, rid, gs, d}:
      cat([maj, min], cat(u16(c), cat(u32(rid), cat(encode_groups(gs), cat([3], d)))))

# ---------------------------------------------------------------------------
# Attribute builders
# ---------------------------------------------------------------------------

def Attr.keyword(name: String, v: String) -> Attr:
  Attr{name, [VText{68, v}]}

def Attr.uri(name: String, v: String) -> Attr:
  Attr{name, [VText{69, v}]}

def Attr.charset(name: String, v: String) -> Attr:
  Attr{name, [VText{71, v}]}

def Attr.language(name: String, v: String) -> Attr:
  Attr{name, [VText{72, v}]}

def Attr.mime(name: String, v: String) -> Attr:
  Attr{name, [VText{73, v}]}

def Attr.name(name: String, v: String) -> Attr:
  Attr{name, [VText{66, v}]}

def Attr.text(name: String, v: String) -> Attr:
  Attr{name, [VText{65, v}]}

def Attr.integer(name: String, n: U32) -> Attr:
  Attr{name, [VInt{33, n}]}

def Attr.enum(name: String, n: U32) -> Attr:
  Attr{name, [VInt{35, n}]}

def Attr.boolean(name: String, b: Bool) -> Attr:
  Attr{name, [VBool{b}]}

def keyword_values(vs: List<&2, String>) -> List<&2, Value>:
  match vs:
    case Nil{}:
      []
    case Con{h, t}:
      VText{68, h} <> keyword_values(t)

# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

# The three attributes every operation group must start with, in the order
# RFC 8011 section 4.1.1 requires: charset, language, then the target.
def op_group(uri: String, rest: List<&2, Attr>) -> Group:
  Group{1, Attr.charset("attributes-charset", "utf-8") <> Attr.language("attributes-natural-language", "en") <> Attr.uri("printer-uri", uri) <> rest}

def requested_attr(reqs: List<&2, String>) -> List<&2, Attr>:
  match reqs:
    case Nil{}:
      []
    case Con{h, t}:
      [Attr{"requested-attributes", VText{68, h} <> keyword_values(t)}]

# Get-Printer-Attributes (0x000B). `requested` lists attribute or group names
# ("marker-levels", "printer-state", "all", "printer-description", ...); an
# empty list asks for the printer's default set.
def get_printer_attributes(uri: String, requested: List<&2, String>, rid: U32) -> Bytes():
  encode(Message{1, 1, 11, rid, [op_group(uri, requested_attr(requested))], []})

# Print-Job (0x0002). `mime` is the document-format, e.g. "application/pdf" or
# "image/urf"; `doc` is the raw document, sent after the end-of-attributes tag.
def print_job(uri: String, user: String, job_name: String, mime: String, rid: U32, doc: Bytes()) -> Bytes():
  encode(Message{1, 1, 2, rid, [op_group(uri, Attr.name("requesting-user-name", user) <> Attr.name("job-name", job_name) <> Attr.mime("document-format", mime) <> [])], doc})

# Validate-Job (0x0004): like Print-Job without a document.
def validate_job(uri: String, user: String, mime: String, rid: U32) -> Bytes():
  encode(Message{1, 1, 4, rid, [op_group(uri, Attr.name("requesting-user-name", user) <> Attr.mime("document-format", mime) <> [])], []})

# ---------------------------------------------------------------------------
# Debug helpers
# ---------------------------------------------------------------------------

def hex_digit(+n: U32) -> Char:
  Bool.pick(Char, U32.is_lt(n, 10), Char.from_u32(U32.add(48, n)), Char.from_u32(U32.add(87, n)))

def hex(bs: Bytes()) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{+b, rest}:
      String.from_list([hex_digit(U32.shrn(b, 4n)), hex_digit(U32.and(b, 15))]) ++ hex(rest)
