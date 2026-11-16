#!/usr/bin/env bash
# Builds the two things you install on a jailbroken iOS 16 device:
#
#   build/ios/FrameMate.ipa                               the app — install with TrollStore
#   build/ios/framemate-tweak_<version>_<arch>.deb        the notification tweak — install with
#                                                         Sileo/Zebra/dpkg, then respring
#
# They are separate on purpose. An app laid down by a .deb under /var/jb/Applications gets a
# sandbox in which WKWebView cannot start its helper processes (a black screen); installed by
# TrollStore it gets a normal app container and works. The tweak has to be a .deb either way.
#
# Tweak layout (rootless):
#   /var/jb/usr/lib/TweakInject/FrameMate.dylib   injected into SpringBoard by ElleKit
#   /var/jb/usr/lib/TweakInject/FrameMate.plist   its filter (com.apple.springboard)
#
# Env:
#   FRAMEMATE_ROOTLESS=0   build a rootful tweak package (Substrate paths, no /var/jb)
#   FRAMEMATE_SKIP_BUILD=1 reuse what is already in build/ios
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/ios"
STAGE="$ROOT/build/ios"
VERSION="0.3.0"
ROOTLESS="${FRAMEMATE_ROOTLESS:-1}"

command -v ldid >/dev/null || { echo "!! ldid not found — 'brew install ldid'." >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "!! dpkg-deb not found — 'brew install dpkg'." >&2; exit 1; }

if [ "${FRAMEMATE_SKIP_BUILD:-0}" != "1" ]; then
  bash "$HERE/build-tweak.sh"
  bash "$HERE/build-app.sh"
fi

for f in "$STAGE/FrameMate.ipa" "$STAGE/FrameMate.dylib" "$STAGE/FrameMate.plist"; do
  [ -e "$f" ] || { echo "!! missing $f — run without FRAMEMATE_SKIP_BUILD first." >&2; exit 1; }
done

echo "==> Fakesigning the tweak"
ldid -S "$STAGE/FrameMate.dylib"

if [ "$ROOTLESS" = "1" ]; then
  LIBDIR="/var/jb/usr/lib/TweakInject"; ARCH="iphoneos-arm64"; DEPENDS="ellekit"
else
  LIBDIR="/Library/MobileSubstrate/DynamicLibraries"; ARCH="iphoneos-arm"; DEPENDS="mobilesubstrate"
fi

PKG="$STAGE/pkg-tweak"
rm -rf "$PKG"
mkdir -p "$PKG$LIBDIR" "$PKG/DEBIAN"
cp "$STAGE/FrameMate.dylib" "$PKG$LIBDIR/FrameMate.dylib"
cp "$STAGE/FrameMate.plist" "$PKG$LIBDIR/FrameMate.plist"

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: dev.framemate.tweak
Name: FrameMate Notifications
Version: $VERSION
Architecture: $ARCH
Description: Forwards phone notifications to a paired Steam Frame (SpringBoard hook). Pairs with the
 FrameMate app (install that via TrollStore).
Section: Tweaks
Depends: $DEPENDS
Maintainer: PositiveRocket (iOS port) <https://github.com/PositiveRocket/framemate-ios>
Author: nailuj05 and the FrameMate contributors; iOS port by PositiveRocket
Homepage: https://github.com/PositiveRocket/framemate-ios
CONTROL
cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
echo "FrameMate Notifications installed. Respring to load it."
exit 0
POSTINST
chmod 0755 "$PKG/DEBIAN/postinst"

OUT="$STAGE/framemate-tweak_${VERSION}_${ARCH}.deb"
dpkg-deb -Zxz --root-owner-group -b "$PKG" "$OUT" >/dev/null
echo "==> Built:"
ls -la "$STAGE/FrameMate.ipa" "$OUT"
lipo -info "$STAGE/FrameMate.dylib"
