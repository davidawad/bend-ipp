# SPDX-License-Identifier: MIT
#
# Shared by the examples: render a decoded Get-Printer-Attributes response as
# text.
import Base
import ../src/ipp.bend as Ipp

def level_text(known: Bool, level: U32) -> String:
  match known:
    case True{}:
      U32.show(level) ++ "%"
    case False{}:
      "unknown"

def marker_line(m: Ipp.Marker) -> String:
  match m:
    case Ipp.Marker{name, color, +level}:
      name ++ " " ++ color ++ " " ++ level_text(Ipp.level_known(level), level)

def marker_lines(ms: List<&2, Ipp.Marker>) -> String:
  match ms:
    case Nil{}:
      ""
    case Con{m, rest}:
      "  " ++ marker_line(m) ++ "\n" ++ marker_lines(rest)

def summary(+m: Ipp.Message) -> String:
  "status: " ++ Ipp.status_name(Ipp.code(m)) ++ "\n"
  ++ "printer-state: " ++ Ipp.printer_state_name(m) ++ "\n"
  ++ "printer-state-reasons: " ++ String.join(Ipp.printer_state_reasons(m), ", ") ++ "\n"
  ++ "markers:\n" ++ marker_lines(Ipp.markers(m))

def summary_r(r: Ipp.Res(Ipp.Message)) -> String:
  match r:
    case Fail{e}:
      "decode error: " ++ e ++ "\n"
    case Done{m}:
      summary(m)
