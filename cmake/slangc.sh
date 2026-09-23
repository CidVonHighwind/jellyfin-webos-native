#!/bin/sh
# Compile one Slang entry point to GLSL ES. See Assets.cmake for why the header
# is rewritten rather than asked for.
set -e
src="$1"; stage="$2"; entry="$3"; short="$4"; out="$5"
command -v slangc >/dev/null || { echo "slangc not found; see README" >&2; exit 1; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
slangc "$src" -target glsl -stage "$stage" -entry "$entry" -o "$tmp"
# The TV's Mali reports ES 3.2; ANGLE, which is where the Windows build gets GLES, offers
# an ES 3.0 context and rejects a 320 shader on it. None of these shaders use anything
# newer than 300, so the version is the caller's to pick.
version="${JF_GLSL_VERSION:-320}"
sed -e "1s|.*|#version $version es\nprecision highp float;\nprecision highp int;|" \
    -e '/^layout(row_major) uniform;$/d' -e '/^layout(row_major) buffer;$/d' \
    "$tmp" > "$out"
if command -v glslangValidator >/dev/null; then glslangValidator -S "$short" "$out" >/dev/null; fi
