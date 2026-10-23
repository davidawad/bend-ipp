#!/bin/sh
# Shell + curl transport: bend builds the request, curl POSTs it, bend decodes
# the reply.   usage: examples/ipp-status.sh HOST[:PORT]     (default port 631)
set -eu
host=${1:?usage: ipp-status.sh HOST[:PORT]}
case "$host" in *:*) ;; *) host="$host:631" ;; esac
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
bend "$here/examples/make_request.bend" "ipp://$host/ipp/print" "$tmp/request.bin"
curl -sf -H 'Content-Type: application/ipp' --data-binary @"$tmp/request.bin" \
  "http://$host/ipp/print" -o "$tmp/response.bin"
bend "$here/examples/printer_status.bend" "$tmp/response.bin"
