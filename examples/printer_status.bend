# SPDX-License-Identifier: MIT
#
# Decode a saved IPP response and print the printer state and ink levels.
#
#   bend examples/printer_status.bend [response.bin]
#
# With no argument it reads the captured fixture. To decode a live response:
#
#   curl -s -H 'Content-Type: application/ipp' \
#        --data-binary @request.bin http://PRINTER:631/ipp/print -o response.bin
#   bend examples/printer_status.bend response.bin
import Base
import ../src/ipp.bend as Ipp
import ../src/hostio.bend as H
import ./report.bend as R

def arg1(args: List<String>) -> String:
  match args:
    case Con{prog, Con{a, rest}}:
      a
    case _:
      "tests/fixtures/get-printer-attributes.response.bin"

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    bs : List<&2, U32> <- H.read_file(arg1(args))
    IO.write(R.summary_r(Ipp.decode(bs)))
