#!/usr/bin/env bash
# Cross-compiles bench/xapi_bench.exe on Linux with clang-cl + lld-link against an
# xwin-splatted MSVC CRT / Windows SDK (see README: "Building on Linux").
#
#   tools/build-bench.sh /path/to/xwin-splat-output
set -euo pipefail
WINSDK="${1:-${WINSDK:-}}"
[ -n "$WINSDK" ] || { echo "usage: $0 /path/to/xwin-splat-output (or set WINSDK)" >&2; exit 2; }
cd "$(dirname "$0")/.."
mkdir -p build

clang-cl --target=x86_64-pc-windows-msvc -fuse-ld=lld-link \
  /imsvc "$WINSDK/crt/include" /imsvc "$WINSDK/sdk/include/ucrt" \
  /imsvc "$WINSDK/sdk/include/um" /imsvc "$WINSDK/sdk/include/shared" \
  /nologo /EHsc /O2 /MT /W3 /std:c++17 -Wno-unused-command-line-argument -Wno-missing-braces \
  /Fobuild/ bench/xapi_bench.cpp \
  /link /libpath:"$WINSDK/crt/lib/x86_64" /libpath:"$WINSDK/sdk/lib/um/x86_64" \
  /libpath:"$WINSDK/sdk/lib/ucrt/x86_64" /SUBSYSTEM:CONSOLE /OUT:build/xapi_bench.exe

echo "built build/xapi_bench.exe"
