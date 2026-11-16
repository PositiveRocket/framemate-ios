#!/usr/bin/env bash
# Builds FrameMate for a jailbroken iOS 16 device as ONE Debian package with the app and the
# notification tweak:
#
#   build/ios/framemate_<version>_<arch>.deb   install with Sileo/Zebra/dpkg, then respring
#   build/ios/FrameMate.ipa                    the app on its own (TrollStore), a by-product
#
# The app can't simply be copied into /var/jb/Applications like many tweak apps: an app laid down
# that way runs in a sandbox where WKWebView can't start its helper processes (a black screen).
# So the package carries the IPA and its postinst installs it through iOS's own installer
# (installd), which gives it a normal app container; removing the package removes the app again.
# Both go through framemate-installer (tweak/installer.m). installd only accepts the fakesigned app
# with AppSync Unified installed. That isn't a package dependency, because AppSync comes from
# different repos under different package IDs; postinst looks for its files instead.
#
# Layout (rootless; rootful drops the /var/jb prefix and uses Substrate's directory):
#   /var/jb/usr/lib/TweakInject/FrameMate.{dylib,plist}         the SpringBoard tweak (ElleKit)
#   /var/jb/usr/share/framemate/FrameMate.ipa                    the app, installed by postinst
#   /var/jb/usr/libexec/framemate/framemate-installer            installs/removes the app
#
# Env:
#   FRAMEMATE_ROOTLESS=0   build a rootful package
#   FRAMEMATE_SKIP_BUILD=1 reuse what is already in build/ios
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/ios"
STAGE="$ROOT/build/ios"
VERSION="0.3.0"
BUNDLE_ID="dev.framemate.app"
ROOTLESS="${FRAMEMATE_ROOTLESS:-1}"

command -v ldid >/dev/null || { echo "!! ldid not found — 'brew install ldid'." >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "!! dpkg-deb not found — 'brew install dpkg'." >&2; exit 1; }

if [ "${FRAMEMATE_SKIP_BUILD:-0}" != "1" ]; then
  bash "$HERE/build-tweak.sh"
  bash "$HERE/build-app.sh"
fi

for f in "$STAGE/FrameMate.ipa" "$STAGE/FrameMate.dylib" "$STAGE/FrameMate.plist" "$STAGE/framemate-installer"; do
  [ -e "$f" ] || { echo "!! missing $f — run without FRAMEMATE_SKIP_BUILD first." >&2; exit 1; }
done

if [ "$ROOTLESS" = "1" ]; then
  PREFIX="/var/jb"; LIBDIR="/var/jb/usr/lib/TweakInject"; ARCH="iphoneos-arm64"; HOOKER="ellekit"
else
  PREFIX=""; LIBDIR="/Library/MobileSubstrate/DynamicLibraries"; ARCH="iphoneos-arm"; HOOKER="mobilesubstrate"
fi
SHARE="$PREFIX/usr/share/framemate"
LIBEXEC="$PREFIX/usr/libexec/framemate"

echo "==> Fakesigning the tweak, the app installer (with its entitlements) and the app"
ldid -S "$STAGE/FrameMate.dylib"
ldid -S"$ROOT/tweak/installer-entitlements.plist" "$STAGE/framemate-installer"
# The IPA from `tauri ios build --no-sign` carries only the linker's ad-hoc signature; give the
# app a proper fake signature so installd (with AppSync Unified) accepts it. The signature's
# identifier must be the bundle id: iOS names the app's data container after it, and the tweak
# finds the app's files through the container iOS reports for the bundle id. (ldid's default, the
# executable's name, put the app's files in a container labelled "FrameMate" instead.)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && unzip -q "$STAGE/FrameMate.ipa" )
ldid -S -I"$BUNDLE_ID" "$WORK/Payload/FrameMate.app/FrameMate"
( cd "$WORK" && zip -qr -X "$WORK/FrameMate.ipa" Payload )

PKG="$STAGE/pkg"
rm -rf "$PKG" "$STAGE/pkg-tweak"
mkdir -p "$PKG$LIBDIR" "$PKG$SHARE" "$PKG$LIBEXEC" "$PKG/DEBIAN"
cp "$STAGE/FrameMate.dylib" "$PKG$LIBDIR/FrameMate.dylib"
cp "$STAGE/FrameMate.plist" "$PKG$LIBDIR/FrameMate.plist"
cp "$WORK/FrameMate.ipa" "$PKG$SHARE/FrameMate.ipa"
install -m 0755 "$STAGE/framemate-installer" "$PKG$LIBEXEC/framemate-installer"

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: dev.framemate.app
Name: FrameMate
Version: $VERSION
Architecture: $ARCH
Description: Companion app for the Steam Frame — mirroring, batteries, downloads and system stats —
 plus a SpringBoard tweak that forwards your phone's notifications to the headset. Needs AppSync
 Unified (from any repo) to install the app.
Section: Applications
Depends: $HOOKER
Conflicts: dev.framemate.tweak
Replaces: dev.framemate.tweak
Maintainer: PositiveRocket (iOS port) <https://github.com/PositiveRocket/framemate-ios>
Author: nailuj05 and the FrameMate contributors; iOS port by PositiveRocket
Homepage: https://github.com/PositiveRocket/framemate-ios
CONTROL

# Installs (or updates) the app from the bundled IPA. An update keeps the app's data, so the
# pairing survives.
cat > "$PKG/DEBIAN/postinst" <<POSTINST
#!/bin/sh
# Asks the package manager to offer a respring when it's done, so SpringBoard loads the tweak.
# Sileo passes "<fd> <version>" in \$SILEO; writing "finish:restart" to that fd turns its "Done"
# button into "Respring" (the same protocol Sileo's own postinst uses).
finish() {
  [ -n "\$SILEO" ] || return 0
  read -r fd ver <<EOF
\$SILEO
EOF
  [ "\$ver" -ge 1 ] 2>/dev/null || return 0
  echo "finish:\$1" >&"\$fd"
}

if [ "\$1" = "configure" ]; then
  if ! ls "$LIBDIR"/AppSyncUnified* >/dev/null 2>&1; then
    echo "Note: AppSync Unified doesn't seem to be installed. iOS needs it to install the FrameMate app."
  fi
  echo "Installing the FrameMate app…"
  if ! "$LIBEXEC/framemate-installer" install "$SHARE/FrameMate.ipa" "$BUNDLE_ID"; then
    echo "Couldn't install the FrameMate app. Check that AppSync Unified is installed and enabled,"
    echo "and that no other copy of FrameMate (e.g. one installed with TrollStore) is on the device."
    exit 1
  fi
  echo "FrameMate installed. Respring to load notification forwarding."
  finish restart
fi
exit 0
POSTINST

# Removes the app with the package; not on upgrades, where postinst installs the new version.
cat > "$PKG/DEBIAN/prerm" <<PRERM
#!/bin/sh
case "\$1" in
  remove|purge)
    "$LIBEXEC/framemate-installer" uninstall "$BUNDLE_ID" || echo "Couldn't remove the FrameMate app; delete it from the home screen."
    ;;
esac
exit 0
PRERM
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm"

OUT="$STAGE/framemate_${VERSION}_${ARCH}.deb"
rm -f "$STAGE"/framemate-tweak_*.deb
dpkg-deb -Zxz --root-owner-group -b "$PKG" "$OUT" >/dev/null
echo "==> Built:"
ls -la "$OUT" "$STAGE/FrameMate.ipa"
