# SPDX-License-Identifier: MIT
#
# Write a Get-Printer-Attributes request body to a file, ready for curl.
#
#   bend examples/make_request.bend ipp://PRINTER:631/ipp/print request.bin
#   curl -s -H 'Content-Type: application/ipp' --data-binary @request.bin \
#        http://PRINTER:631/ipp/print -o response.bin
import Base
import ../src/ipp.bend as Ipp
import ../src/hostio.bend as H

def args2(args: List<String>) -> String & String:
  match args:
    case Con{prog, Con{uri, Con{out, rest}}}:
      (uri, out)
    case _:
      ("ipp://localhost:631/ipp/print", "request.bin")

def go(a: String & String) -> IO(Unit):
  (uri, out) = a
  H.write_file(out, Ipp.get_printer_attributes(uri, ["marker-names", "marker-levels", "marker-colors", "printer-state", "printer-state-reasons"], 1))

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    go(args2(args))
