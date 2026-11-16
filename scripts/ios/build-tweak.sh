#!/usr/bin/env bash
# Builds the SpringBoard tweak (FrameMate.dylib, arm64 + arm64e) and the package's app
# installer (framemate-installer) with Theos, and stages them in build/ios/.
#
# Theos refuses project paths that contain spaces, and this repo may well sit in one (e.g. under
# "Application Support"), so the tweak is built in a temporary copy under a space-free directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${THEOS:=$HOME/theos}"
export THEOS
# rootless (Dopamine / rootless palera1n) by default; set FRAMEMATE_ROOTLESS=0 for a rootful build.
if [ "${FRAMEMATE_ROOTLESS:-1}" = "1" ]; then SCHEME=rootless; else SCHEME=; fi

[ -d "$THEOS" ] || { echo "!! Theos not found at $THEOS — install it (https://theos.dev) or set THEOS." >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/framemate-tweak.XXXXXX")"
case "$WORK" in
  *" "*) echo "!! Temp dir has spaces ($WORK); set TMPDIR to a space-free path." >&2; exit 1;;
esac
trap 'rm -rf "$WORK"' EXIT

cp -R "$ROOT/tweak/." "$WORK/"
echo "==> Building tweak in $WORK (scheme=${SCHEME:-rootful})"
# FINALPACKAGE: optimised, no debug logging.
make -C "$WORK" THEOS_PACKAGE_SCHEME="$SCHEME" FINALPACKAGE=1 clean all

# The final linked+signed dylib sits directly in obj/<variant>/, not in the per-arch subdirs.
DYLIB="$(find "$WORK/.theos/obj" -name FrameMate.dylib -not -path '*/arm64/*' -not -path '*/arm64e/*' | head -1)"
[ -n "$DYLIB" ] || { echo "!! the build produced no FrameMate.dylib" >&2; exit 1; }
mkdir -p "$ROOT/build/ios"
cp "$DYLIB" "$ROOT/build/ios/FrameMate.dylib"
cp "$ROOT/tweak/FrameMate.plist" "$ROOT/build/ios/FrameMate.plist"
TOOL="$(find "$WORK/.theos/obj" -name framemate-installer -type f -not -path '*/arm64/*' -not -path '*/arm64e/*' | head -1)"
[ -n "$TOOL" ] || { echo "!! the build produced no framemate-installer" >&2; exit 1; }
cp "$TOOL" "$ROOT/build/ios/framemate-installer"
echo "==> Staged build/ios/FrameMate.dylib and build/ios/framemate-installer"
lipo -info "$ROOT/build/ios/FrameMate.dylib"
lipo -info "$ROOT/build/ios/framemate-installer"
