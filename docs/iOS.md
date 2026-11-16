# FrameMate on iOS (jailbroken, iOS 16)

This is the iOS port of FrameMate. It comes in two parts:

| Part | What it does | How it is installed |
|---|---|---|
| **FrameMate.ipa** — the companion app | mirroring, batteries, downloads, system stats, pairing, notification settings | **TrollStore** |
| **framemate-tweak … .deb** — the notification tweak | forwards the phone's notifications to the headset | **Sileo / Zebra / dpkg**, then respring |

## Why a jailbreak, and why two packages

Reading *other apps'* notifications is impossible from a normal, sandboxed iOS app — there is no
public API for it, and TrollStore entitlements don't change that. The only way is a **tweak
injected into SpringBoard**, which requires a jailbreak. So the notification half is a SpringBoard
tweak (modelled on [ForwardNotifier](https://github.com/Greg0109/ForwardNotifier)), shipped as a
`.deb`.

The app is *not* in that `.deb`. An app laid down by a package under `/var/jb/Applications` runs in
a sandbox where WKWebView cannot start its helper processes (`com.apple.WebKit.WebContent`/`GPU`/
`Networking`), so the UI never renders — a black screen — and no fakesigned entitlement fixes it.
Installed through TrollStore the app gets a normal container and works.

## Architecture

The upstream app is a Tauri 2 app (Svelte frontend + Rust shell), which is already cross-platform;
only the notification capture and a little native glue were Android-specific.

```
   FrameMate.app (TrollStore)                        SpringBoard
  ┌──────────────────────────────┐                 ┌───────────────────────────────┐
  │ Svelte UI                    │                 │ FrameMate.dylib (tweak, ObjC) │
  │ Tauri commands (lib.rs)      │                 │  hooks -[BBServer             │
  │ framemate-core (Rust):       │                 │   publishBulletin:…]          │
  │  pairing · proxy · prefs     │                 │  NSURLSession, pinned key     │
  └───────┬───────────────┬──────┘                 └───────┬──────────────┬────────┘
          │ pinned TLS    │ read/write                     │ read/write   │ pinned TLS
          │               ▼                                ▼              │ POST /api/notify
          │       <container>/Documents/FrameMate/                        │
          │         pairing.json   notifications.json                     │
          ▼                                                               ▼
        ─────────────────────────── the Frame (agent) ───────────────────────────
```

- **`app/src-tauri/core`** (`framemate-core`) — the shared Rust crate: `pairing`, `proxy` (pinned
  TLS to the Frame), `forward` (`POST /api/notify`, used by the app's test button), `prefs` (the
  forwarding settings, ported from Android's `NotificationPrefs.kt`) and `store` (file names).
- **`app/src-tauri/src/lib.rs`** — the Tauri app. On iOS the notification settings are Tauri
  commands (the generated iOS app has no WebView bridge like Android's `MainActivity`).
- **`app/src/lib/native.ts`** — the frontend abstraction: Android talks to
  `window.FrameMateAndroid`, iOS talks to Tauri commands + the opener plugin.
- **`tweak/`** — the SpringBoard tweak (Theos/Logos, plain Objective-C). It hooks
  `-[BBServer publishBulletin:destinations:]`, copies the notification's text, and on its own
  queue checks the settings and sends the toast with `NSURLSession`, trusting only the key pinned
  at pairing.

### Why the tweak is not Rust

The first version linked `framemate-core` into the tweak through a C ABI, to reuse the sending
path. It crashed SpringBoard into safe mode on the first forwarded notification: SpringBoard is an
**arm64e** process on A12 and newer, and Rust's `arm64e-apple-ios` target (tier 3) does not emit
pointer authentication, so thread-local access and callbacks jump through signed pointers
unauthenticated. The tweak therefore re-implements the small part it needs — read two JSON files,
one pinned HTTPS POST — with system frameworks only. The formats it shares with the Rust core:

- `pairing.json`: `{host, ip, port, token, pin}` (`core/src/pairing.rs`)
- `notifications.json`: `{enabled, disabled_apps, seen, last_result, last_time}` (`core/src/prefs.rs`)
- the pin: first 128 bits of SHA-256(SubjectPublicKeyInfo), Crockford base32 (`core/src/proxy.rs`)

Change one side and the other has to follow.

### Shared configuration

The app keeps both files in `Documents/FrameMate` inside its own container (`$HOME/Documents/
FrameMate`). The tweak, inside SpringBoard, finds the same directory from the app's container URL
(`LSApplicationProxy.dataContainerURL`).

> The app must be **launched once and paired** before the tweak has anything to forward to.

### Mirroring on iPhone

The agent streams fragmented MP4 for Media Source Extensions, which iPhones only have from
iOS 17.1 (as `ManagedMediaSource`). On older iPhones the player takes the H.264 frames out of the
container itself (`app/src/lib/fmp4.ts`), decodes them with WebCodecs and paints them on a canvas.
That needs **iOS 16.4 or newer**; below that the page says so.

iOS 16.4's WebCodecs decoder has three quirks the player works around
(`app/src/routes/view/+page.svelte`), all found on a device:

- It rejects the stream given as `avcC` + length-prefixed samples ("Decoder failure" on the first
  frame) but accepts the same frames as an **Annex B** stream with no `description`. The player
  tries the `avcC` form first, switches on a failure before the first frame, and remembers the
  form that worked (`localStorage`).
- Frames drawn straight onto a canvas keep the decoder's output buffers busy; after ~120 frames it
  silently stops producing any. Each frame is therefore copied with `createImageBitmap`, released
  at once, and the copy is drawn. A watchdog replaces the decoder if frames still stop coming out.
- A WebSocket error is not always followed by a close event, so an error alone counts as a lost
  connection and triggers the reconnect.

### Filling the screen

The page lays itself out under the status bar and home indicator (`viewport-fit=cover`) and pads
its own bars by `env(safe-area-inset-*)`. WKWebView, though, sizes the page from the safe area at
its first layout and doesn't re-measure when the scroll view's inset behaviour changes later, which
left a black strip below the tab bar. `fill_the_screen` in `src-tauri/src/lib.rs` sets the inset
behaviour to "never" at startup and on every page load, and nudges the webview's frame by a point
so WebKit re-measures.

## Building

### Host requirements (macOS)

- Xcode (16.x) and its command-line tools
- [Rust](https://rustup.rs) with the `aarch64-apple-ios` target (`rustup target add aarch64-apple-ios`)
- [deno](https://deno.com) (builds the Svelte frontend)
- [Theos](https://theos.dev) at `$THEOS` (builds the tweak)
- `ldid`, `dpkg`, `xcodegen` — `brew install ldid dpkg xcodegen`

> Theos refuses project paths containing spaces. The build copies the tweak to a space-free temp
> dir automatically.

### One command

```sh
scripts/ios/package.sh
```

This builds the tweak (arm64 + arm64e) and the unsigned app, and writes
`build/ios/FrameMate.ipa` and `build/ios/framemate-tweak_0.3.0_iphoneos-arm64.deb`.

| Variable | Default | Meaning |
|---|---|---|
| `FRAMEMATE_ROOTLESS=0` | rootless | Build a **rootful** tweak package instead of rootless (Dopamine / rootless palera1n). |
| `FRAMEMATE_SKIP_BUILD=1` | off | Reuse what's already in `build/ios` (just re-sign and re-package). |

The individual steps are `scripts/ios/build-tweak.sh` and `scripts/ios/build-app.sh`.

The app icon's source is `app/src-tauri/icons/FrameMate.icon` (Apple Icon Composer). The PNGs in
`app/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset` are a flattened render of it (the
liquid-glass look needs iOS 18); after changing the `.icon`, regenerate them with
`scripts/ios/render-icon.sh`. Only the iOS icon comes from there: Android, desktop and the in-app
logo use upstream's artwork.

## Installing

1. **App:** open `FrameMate.ipa` in TrollStore and install.
2. **Tweak:** install the `.deb` with Sileo/Zebra, or over SSH:
   ```sh
   dpkg -i framemate-tweak_0.3.0_iphoneos-arm64.deb
   ```
   then **respring**. Its dependency, `ellekit` (rootless) / `mobilesubstrate` (rootful), is
   already present on a jailbroken device.

## Using it

1. On the Frame, run `flatpak run --user dev.framemate.Agent pair` and keep the QR code up.
2. Open **FrameMate**, go to **Settings → Connection**, scan the code (or type it).
3. Tap the **bell** in the top bar to turn notifications on, and pick which apps forward under
   **Settings → Notifications → Apps**. Use **Send a test notification** to check the path.

Notifications go only from your phone to your Frame, over the pinned-TLS connection, and are never
stored.

## Status and limitations

Checked on the build machine: the core's unit tests; the tweak's TLS code against a local TLS 1.3
server (right key accepted, wrong key and wrong token refused, fallback between addresses); the
fMP4 reader against segments from the agent's own muxer; and the WebCodecs player on real H.264 in
Chromium and Safari, including a simulated stalling decoder. On an iPhone (iOS 16.4.1, rootless
jailbreak) against a Steam Frame: pairing, mirroring, the app filling the screen, and notifications
reaching the headset with the app closed.

Worth checking on a device after any change to the tweak:

- The notification hook. `-[BBServer publishBulletin:destinations:]` is the long-standing hook
  (what ForwardNotifier uses). Icons come from a private UIKit call and are best-effort; a toast
  still shows without one.
- That SpringBoard can write the app's container directory. Reading the pairing is the critical
  path; if writes fail, the "seen apps" list and last-send status won't update, but forwarding
  still works.

Known gaps versus Android:

- **Mirroring fullscreen orientation** is not forced to landscape on iOS (the WebView rotates with
  the device).
- The "notification access" concept on iOS is simply *the tweak being installed*; there is no OS
  permission screen, and the Settings page says so.
