#!/usr/bin/env bash
# Builds the FrameMate iOS app (unsigned, arm64) and stages it at build/ios/FrameMate.ipa, ready
# to install with TrollStore (plus the unpacked bundle at build/ios/FrameMate.app).
#
# Uses `tauri ios build --no-sign`, so no Apple developer account or signing identity is needed —
# TrollStore signs on install. deno builds the Svelte frontend (build.beforeBuildCommand).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app"
GEN="$APP/src-tauri/gen/apple"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-14.0}"

# Rust writes source paths into the binary (panic locations), which would put the builder's home
# folder — and so their user name — into every build. Map it to `~`. This can't go through
# RUSTFLAGS: the Xcode build phase runs cargo with a pared-down environment. A cargo config file is
# read regardless, so one is written next to the crate for the duration of the build (ignored by
# git, removed afterwards).
CARGO_CONFIG_DIR="$APP/src-tauri/.cargo"
CARGO_CONFIG="$CARGO_CONFIG_DIR/config.toml"
if [ -e "$CARGO_CONFIG" ] && ! grep -q "framemate build-app.sh" "$CARGO_CONFIG"; then
  echo "!! $CARGO_CONFIG exists and isn't ours; not touching it (paths stay unmapped)." >&2
else
  mkdir -p "$CARGO_CONFIG_DIR"
  python3 -I - "$HOME" "$CARGO_CONFIG" <<'PY2'
import json, sys
home, out = sys.argv[1], sys.argv[2]
open(out, "w").write(
    "# Written by framemate build-app.sh for one build; safe to delete.\n"
    "[target.aarch64-apple-ios]\n"
    f"rustflags = [{json.dumps('--remap-path-prefix=' + home + '=~')}]\n"
)
PY2
  trap 'rm -f "$CARGO_CONFIG"; rmdir "$CARGO_CONFIG_DIR" 2>/dev/null || true' EXIT
fi

command -v cargo >/dev/null || { echo "!! cargo not found — install Rust (rustup)." >&2; exit 1; }
command -v deno  >/dev/null || { echo "!! deno not found — install deno." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "!! xcodegen not found — 'brew install xcodegen'." >&2; exit 1; }

cd "$APP"
[ -d node_modules ] || deno install
rustup target list --installed | grep -q aarch64-apple-ios || rustup target add aarch64-apple-ios

# tauri ios build does not re-run xcodegen, so regenerate the Xcode project from project.yml here
# to pick up Info.plist / build-script changes.
( cd "$GEN" && xcodegen generate )

node_modules/.bin/tauri ios build --target aarch64 --no-sign --ci

IPA="$GEN/build/arm64/FrameMate.ipa"
[ -f "$IPA" ] || { echo "!! build did not produce $IPA" >&2; exit 1; }

STAGE="$ROOT/build/ios"
mkdir -p "$STAGE"
rm -rf "$STAGE/app-extract" "$STAGE/FrameMate.app"
mkdir -p "$STAGE/app-extract"
( cd "$STAGE/app-extract" && unzip -q "$IPA" )
cp -R "$STAGE/app-extract/Payload/FrameMate.app" "$STAGE/FrameMate.app"
rm -rf "$STAGE/app-extract"
cp "$IPA" "$STAGE/FrameMate.ipa"
echo "==> Staged build/ios/FrameMate.ipa"
lipo -info "$STAGE/FrameMate.app/FrameMate"
