# FrameMate on iOS (jailbroken, iOS 16)

This is the iOS port of FrameMate. It installs as **one package**, `framemate_<version>_iphoneos-arm64.deb`,
which contains:

| Part | What it does |
|---|---|
| **the FrameMate app** | mirroring, batteries, downloads, system stats, pairing, notification settings |
| **the notification tweak** (`FrameMate.dylib`) | forwards the phone's notifications to the headset, from inside SpringBoard |

## Why a jailbreak, and how the app gets installed

Reading *other apps'* notifications is impossible from a normal, sandboxed iOS app — there is no
public API for it, and TrollStore entitlements don't change that. The only way is a **tweak
injected into SpringBoard**, which requires a jailbreak. So the notification half is a SpringBoard
tweak (modelled on [ForwardNotifier](https://github.com/Greg0109/ForwardNotifier)), shipped as a
`.deb`.

The app isn't simply copied into `/var/jb/Applications`, as many tweak apps are. An app laid down
that way runs in a sandbox where WKWebView cannot start its helper processes
(`com.apple.WebKit.WebContent`/`GPU`/`Networking`), so the UI never renders — a black screen — and
no fakesigned entitlement fixes it. Installed through iOS's own installer (installd) it gets a
normal app container and works. So the package carries `FrameMate.ipa`, and its `postinst` hands it
to installd with `framemate-installer` (`tweak/installer.m`), the same way
[AppSync Unified](https://github.com/akemin-dayo/AppSync)'s `appinst` does; removing the package
runs it again to uninstall the app. installd only accepts the fakesigned app with **AppSync
Unified** installed. That isn't a package dependency: AppSync is published by several repos under
different package IDs, so a dependency on one ID fails on devices that have it from another.
`postinst` looks for AppSync's files instead and says so if they're missing.

## Architecture

The upstream app is a Tauri 2 app (Svelte frontend + Rust shell), which is already cross-platform;
only the notification capture and a little native glue were Android-specific.

```
   FrameMate.app (installd)                          SpringBoard
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
FrameMate`). iOS names an app's data container after the identifier in its code signature, so the
package signs the app as `dev.framemate.app` (`ldid -I`); signed with ldid's default, the
executable's name, the app ran in a container labelled "FrameMate" while LaunchServices reported
another one for the bundle id. The tweak, inside SpringBoard, looks for `pairing.json` in the
container iOS reports, and as a safety net in every app data container (and `/var/mobile`), using
the newest pairing it finds. The search runs once and is remembered.

On disk there are only these two files. `notifications.json` is written when a setting changes,
when an app posts its first notification, and when the result of a send or the pause changes. The
tweak's log lines (`idevicesyslog -m "FrameMate: "`) use iOS's in-memory levels and are never saved.

> The app must be **launched once and paired** before the tweak has anything to forward to.

### Forwarding notifications

The tweak follows the Android listener (`FrameNotificationListener.kt`):

- Duplicates are recognised per notification and its post time, so an app re-posting the same
  notification (progress, updates) sends one toast, while a new message with the same text as an
  earlier one still goes through.
- At most 10 notifications wait to be sent; beyond that the oldest give way. One that waited more
  than 30 seconds for its turn is dropped. Notifications dated more than 2 minutes back when they
  arrive are what iOS replays after a respring, and are ignored.

One addition: when the Frame can't be reached (asleep, off, on another network), forwarding
**pauses** instead of waiting up to 5 seconds per address for every notification. While paused,
notifications are skipped without touching the network, and a quick check (1.5 seconds at most)
is made on the next notification after 1, then 2, then every 5 minutes. The pause ends when that
check succeeds, when the phone joins Wi-Fi, when the app connects to the Frame, or on "Send a test
notification". It never changes the bell; the Settings page shows "Paused" while it lasts. The
state lives in `notifications.json` (`paused_since`, `pause_next_check`, `pause_step`).

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

This builds the tweak and `framemate-installer` (arm64 + arm64e) and the app, and writes
`build/ios/framemate_0.3.0_iphoneos-arm64.deb`. The app on its own, `build/ios/FrameMate.ipa`, is a
by-product, for installing it with TrollStore instead (without notifications in VR).

| Variable | Default | Meaning |
|---|---|---|
| `FRAMEMATE_ROOTLESS=0` | rootless | Build a **rootful** package instead of rootless (Dopamine / rootless palera1n). |
| `FRAMEMATE_SKIP_BUILD=1` | off | Reuse what's already in `build/ios` (just re-sign and re-package). |

The individual steps are `scripts/ios/build-tweak.sh` and `scripts/ios/build-app.sh`.

The app icon's source is `app/src-tauri/icons/FrameMate.icon` (Apple Icon Composer). The PNGs in
`app/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset` are a flattened render of it (the
liquid-glass look needs iOS 18); after changing the `.icon`, regenerate them with
`scripts/ios/render-icon.sh`. Only the iOS icon comes from there: Android, desktop and the in-app
logo use upstream's artwork.

## Installing

You need **AppSync Unified** installed and enabled, from whichever repo you use. Then install
`framemate_0.3.0_iphoneos-arm64.deb` with Sileo or Zebra, and **respring**: Sileo offers a
**Respring** button when it's done (the package's `postinst` asks for it through Sileo's `$SILEO`
channel); with other package managers, respring yourself. Its only package
dependency is `ellekit` (rootless) / `mobilesubstrate` (rootful), which a jailbroken device
already has. Over SSH:

```sh
dpkg -i framemate_0.3.0_iphoneos-arm64.deb
```

Installing puts FrameMate on the home screen; removing the package removes it. Updating the
package keeps the app's data, so the pairing survives. (Once only: the first update that signs
the app as `dev.framemate.app` moves it to a new container, so it needs pairing again.)

> **Coming from the two-package version** (app from TrollStore + `framemate-tweak` .deb): delete
> FrameMate in TrollStore first. The new package replaces the old tweak by itself. Deleting the
> app clears the pairing, so scan the code again afterwards.

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
jailbreak) against a Steam Frame: installing and updating the single package, pairing, mirroring,
the app filling the screen, notifications reaching the headset with the app closed, and the pause
while the Frame is off.

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
