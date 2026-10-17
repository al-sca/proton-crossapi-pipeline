#!/usr/bin/env bash
# Cross-compiles DLSS5-Feeder's dlss5-feed.addon64 on Linux: the repo's tools/build.bat
# translated to clang-cl + lld-link against an xwin-splatted MSVC CRT / Windows SDK.
#
#   tools/build-dlss5-feeder.sh /path/to/DLSS5-Feeder /path/to/xwin-splat-output
#
# The Feeder checkout needs the NGX SDK (external/ngx, see its README) and the Khronos
# Vulkan headers (external/vulkan, see its README); neither is redistributed there.
set -euo pipefail
REPO="${1:?path to DLSS5-Feeder}"
WINSDK="${2:?path to xwin splat output}"
cd "$REPO"

for f in external/ngx/nvsdk_ngx.h external/ngx/libs/nvsdk_ngx_d.lib external/vulkan/vulkan/vulkan_core.h; do
  [ -f "$f" ] || { echo "missing $REPO/$f -- see the README next to it" >&2; exit 1; }
done

BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo -dirty)"
mkdir -p build

SYS=(/imsvc "$WINSDK/crt/include" /imsvc "$WINSDK/sdk/include/ucrt"
     /imsvc "$WINSDK/sdk/include/um" /imsvc "$WINSDK/sdk/include/shared")
LIBS=(/libpath:"$WINSDK/crt/lib/x86_64" /libpath:"$WINSDK/sdk/lib/um/x86_64"
      /libpath:"$WINSDK/sdk/lib/ucrt/x86_64")

llvm-rc /nologo /I "$WINSDK/sdk/include/um" /I "$WINSDK/sdk/include/shared" \
  /fo build/version.res src/version.rc

clang-cl --target=x86_64-pc-windows-msvc -fuse-ld=lld-link "${SYS[@]}" \
  /nologo /LD /EHsc /O2 /MD /W3 /std:c++20 \
  -Wno-unused-command-line-argument -Wno-microsoft -Wno-unknown-pragmas \
  "/DFEED_BUILD_ID=\"$BUILD_ID\"" \
  /Iexternal/reshade/include /Iexternal/ngx /Iexternal/vulkan /Iexternal/imgui /Iexternal/minhook/include \
  /Fobuild/ \
  src/dlss5-feed.cpp external/minhook/src/buffer.c external/minhook/src/hook.c \
  external/minhook/src/trampoline.c external/minhook/src/hde/hde64.c \
  /link "${LIBS[@]}" /OUT:build/dlss5-feed.addon64 /IMPLIB:build/dlss5-feed.lib build/version.res \
  external/ngx/libs/nvsdk_ngx_d.lib version.lib kernel32.lib user32.lib advapi32.lib ole32.lib

echo "built build/dlss5-feed.addon64 ($BUILD_ID)"
