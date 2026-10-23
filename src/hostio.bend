# SPDX-License-Identifier: MIT
#
# Optional host I/O helpers for bend-ipp: read and write raw byte files.
# The codec in ipp.bend does not import this; it exists so tests and examples
# can move IPP messages in and out of files (and so a shell can pipe them to
# curl).
import Base

def read_go(m: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(List<&2, U32>):
  (f, r) = m
  do IO<List<&2, U32>>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    u : Unit <- File.close(f)
    return xs

# Read a whole file (up to 16 MiB) as bytes. Exits with the error on failure.
def read_file(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    g : File <- IO.try(File, File.open(path, "r"))
    m : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(g, 16777216)
    read_go(m)

def write_go(w: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, r) = w
  do IO<Unit>:
    u : Unit <- IO.pass(Unit, r)
    File.close(f)

# Write bytes to a file, replacing it. Exits with the error on failure.
def write_file(path: String, bs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    g : File <- IO.try(File, File.open(path, "w"))
    w : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(g, bs)
    write_go(w)
