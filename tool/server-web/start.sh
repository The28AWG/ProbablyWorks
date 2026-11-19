#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec ./server/bin/pw_server --web-dir web --print-token "$@"
