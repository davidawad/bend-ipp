# SPDX-License-Identifier: MIT
#
# End to end, no shell: build a Get-Printer-Attributes request, POST it over
# a raw TCP socket (HTTP/1.0, so no chunked bodies), decode the reply, print.
#
#   bend examples/ipp_status.bend 192.168.86.235
#
# Bend's TCP kit takes an IPv4 literal (no DNS, so no .local names). This is
# the host layer: the codec in src/ipp.bend knows nothing about sockets.
import Base
import ../src/ipp.bend as Ipp
import ./report.bend as R

# Bytes after the first blank line (CR LF CR LF) of an HTTP response.
def http_body(bs: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Nil{}:
      []
    case Con{13, Con{10, Con{13, Con{10, rest}}}}:
      rest
    case Con{_, t}:
      http_body(t)

def http_post(host: String, port: String, +body: List<&2, U32>) -> List<&2, U32>:
  +len = List.length(&2, U32, body)
  List.append(&2, U32, Ipp.utf8.encode("POST /ipp/print HTTP/1.0\r\nHost: " ++ host ++ ":" ++ port ++ "\r\nContent-Type: application/ipp\r\nContent-Length: " ++ Nat.show(len) ++ "\r\n\r\n"), body)

def fail(s: Socket, code: U32, message: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    Socket.close(s)
    IO.die(List<&2, U32>, code, message)

def done(s: Socket, chunks: List<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    Socket.close(s)
    return List.concat(&2, U32, List.reverse(&2, List<&2, U32>, chunks))

# Read until the peer closes (HTTP/1.0 close-delimited body).
def read_all(fuel: Nat, m: Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, chunks: List<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match fuel:
    case 0n:
      (s, r) = m
      fail(s, 1, "response too large")
    case 1n+p:
      (s, r) = m
      match r:
        case Fail{(code, message)}:
          fail(s, code, message)
        case Done{None{}}:
          done(s, chunks)
        case Done{Some{chunk}}:
          do IO<List<&2, U32>>:
            next : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 8192)
            read_all(p, next, chunk <> chunks)

def after_send(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(List<&2, U32>):
  (s, r) = m
  match r:
    case Fail{((code, message), rest)}:
      fail(s, code, message)
    case Done{u}:
      do IO<List<&2, U32>>:
        first : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 8192)
        read_all(4096n, first, [])

def arg1(args: List<String>) -> String:
  match args:
    case Con{prog, Con{a, rest}}:
      a
    case _:
      "127.0.0.1"

def query(+host: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    c : Socket <- IO.try(Socket, TCP.connect(host, 631))
    sent : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(c, http_post(host, "631", Ipp.get_printer_attributes("ipp://" ++ host ++ ":631/ipp/print", ["marker-names", "marker-levels", "marker-colors", "printer-state", "printer-state-reasons"], 1)))
    after_send(sent)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    resp : List<&2, U32> <- query(arg1(args))
    IO.write(R.summary_r(Ipp.decode(http_body(resp))))
