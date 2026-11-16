<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/framemate-white.png">
    <img src="assets/framemate-white.png" alt="FrameMate logo" width="128">
  </picture>
</p>

<h1 align="center">FrameMate</h1>

<p align="center">
  A companion app for the <b>Steam Frame</b>: mirror the headset to your phone, receive phone notifications in VR, keep an eye on battery, controllers, downloads and what's playing. <a href="https://youtu.be/Tva1_8JajW4">Demo Video</a>
</p>

> ## Fork notice
>
> **This is an unofficial fork, not the original project.** It is a fork of
> [`nailuj05/framemate`](https://github.com/nailuj05/framemate) that adds **iOS support** — the app
> for **jailbroken iOS 16** (installed with TrollStore) and a SpringBoard **notification tweak** —
> see [iOS support](#ios-support-this-fork) and [`docs/iOS.md`](docs/iOS.md). The Steam Frame
> agent, the Android app, the mirroring/pairing code and the Svelte UI are the work of
> [nailuj05](https://github.com/nailuj05) and the FrameMate contributors.
>
> It is **not endorsed by** the original author. Under
> [`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md) §2 the name **FrameMate**, the FrameMate logo and
> the `dev.framemate.*` application identifiers are reserved by the original author. This fork still
> uses them (and its iOS icon is based on the logo), so **don't redistribute builds of it as a
> separate project** without renaming it, replacing the logo and the iOS icon, and choosing your own
> identifiers. See [Changes in this fork](#changes-in-this-fork).

## At a glance

<p align="center">
  <img src="docs/screenshots/home.png" alt="Home: headset and controller batteries, now playing, active download" width="250">
  &nbsp;
  <img src="docs/screenshots/downloads.png" alt="Downloads: queue with progress and recently finished games" width="250">
  &nbsp;
  <img src="docs/screenshots/system.png" alt="System: headset, performance and network details" width="250">
</p>

## Mirroring

<p align="center">
  <img src="docs/screenshots/mirroring.png" alt="Mirroring in fullscreen landscape on a phone" width="760">
</p>

FrameMate mirrors what the headset shows to your phone. Show your friends what
you're doing in VR, guide someone through their first session, or just check what's on
screen. The picture is the actual view in the headset, passthrough included. Encoded using hardware acceleration to keep
the load low.

## Notifications in VR

<p align="center">
  <img src="docs/screenshots/notif-vr.jpg" alt="A phone notification shown as a Steam toast in the SteamVR dashboard" width="760">
</p>

Your phone's notifications show up in the headset as Steam notifications, so you
don't have to take the headset off to check your phone. It is a opt-in feature: turn it on with the bell in the
app's top bar. You can select which apps notifications you want in there.

## Features

- **Headset battery** – the same percentage Steam shows in the headset, charging state,
  time left or time to full, and current power draw.
- **Controller batteries** – both controllers, including while they sleep (the last known
  level is remembered across restarts).
- **Now playing** – the running game with its Steam artwork.
- **Downloads** – the Frame's download queue with progress, speed and time left, plus recently
  finished updates. Downloads of your other PCs (Steam Remote Downloads) are left out.
- **Mirroring** – see above.
- **Phone notifications in VR** – your phone's notifications show up in the headset as normal
  Steam toasts. It's opt-in: off by default, you turn it on with the bell in the app's top bar.
  Apps you don't want in there can be switched off in the settings. Turn it off again just as
  quickly, e.g. when someone else is wearing the headset. Nothing gets stored, it only goes from your phone to your Frame.
- **System** – performance profile, CPU/GPU settings, network throughput, SteamOS and Steam
  client versions, battery temperature and health.
- **Encrypted** – the phone talks to the Frame over TLS, pinned to the Frame's own key from the
  pairing code. Implementation inspired by KDEConnect
  - **Lightweight** – the agent on the Frame is a single static binary (~6.5 MB, a few MB of
  RAM) that idles at practically zero CPU.

## Installation

You need a Steam Frame and a phone — **Android**, or an **iPhone on jailbroken iOS 16** (this
fork, see below) — on the same network.

### 1. Agent on the Steam Frame

Open a terminal on the Frame via SSH (recommended), or Desktop Mode → Konsole
([see here](TROUBLESHOOTING.md#installing-from-desktop-mode)), and run:

```sh
curl -LsSf https://raw.githubusercontent.com/nailuj05/framemate/main/scripts/install.sh | sh
```

That installs the Flatpak, registers the user service, runs a self check and prints the pairing
QR code. Re-run the same command to update. If you'd rather not pipe a script into a shell,
[read it first](scripts/install.sh); it only runs the manual commands below.

<details>
<summary>Or do it by hand</summary>

```sh
curl -LO https://github.com/nailuj05/framemate/releases/latest/download/framemate-agent.flatpak
flatpak install --user -y framemate-agent.flatpak
flatpak run --user dev.framemate.Agent install-service
flatpak run --user dev.framemate.Agent pair
rm framemate-agent.flatpak
```
</details>

- `flatpak install` pulls the Freedesktop runtime from Flathub if it isn't installed yet
  (about 270 MB, once).
- `install-service` registers a user service, so the agent starts with every boot (in
  Game Mode too) and restarts it right away, then runs a self check.
  In Desktop Mode it can't start the agent right away (the nested desktop has no access to the
  user's systemd); the agent then starts with the next restart, and the command prints how to
  start it immediately. Either way `pair` prints the pairing code afterwards.
- `flatpak run --user dev.framemate.Agent pair` prints the pairing code again, as a QR code and
  as plain text for terminals too narrow to draw it. It contains the access token, so treat it
  like a password.
- `flatpak run --user dev.framemate.Agent check` repeats the self check, which helps when the app
  can't connect. `token` prints just the token. `rotate-token` replaces it, so run `pair`
  afterwards and scan again: the app takes the token from the pairing code. Rotating leaves the
  encryption key alone, so it doesn't change who the app trusts.

To **remove** it:

```sh
curl -LsSf https://raw.githubusercontent.com/nailuj05/framemate/main/scripts/install.sh | sh -s -- uninstall
```

### 2. App on your phone

**Android** (upstream):

1. Download `framemate.apk` from the [latest release](../../releases/latest) on your phone.
2. Open it and allow your browser/file manager to install apps when Android asks.
3. In the app's **Settings** tab, tap **Scan pairing code** and point the camera at the QR code
   from step 1. The code contains all information the app needs to find your frame, authenticate with it and verify its certificate.

**iOS** (this fork, jailbroken iOS 16, rootless — e.g. Dopamine or palera1n): the app and the
notification forwarding are two packages, built with `scripts/ios/package.sh`
([`docs/iOS.md`](docs/iOS.md) has the details):

1. Install `FrameMate.ipa` with **TrollStore**.
2. Install `framemate-tweak_<version>_iphoneos-arm64.deb` with Sileo/Zebra (or `dpkg -i`) and
   **respring**. It's only needed for notifications in VR.
3. Open the app, and in the **Settings** tab scan the pairing code, as on Android.

The app doesn't need to be running for notifications to reach the Frame: the tweak works inside
SpringBoard. After the phone restarts, unlock it once before notifications are forwarded (iOS keeps
the pairing locked until then). Mirroring needs iOS 16.4 or newer.

### Troubleshooting

If you encounter any issues please check out [TROUBLESHOOTING](TROUBLESHOOTING.md).

## Good to know

- **Unofficial.** FrameMate relies on undocumented Steam internals. A Steam or SteamOS update can
  break parts of it until the agent is updated. Tested on SteamOS 0.4.3 (beta branch).
- **Encrypted, local network only.** The app connects on port 7381 over TLS, pinned to the key
  whose fingerprint came from the pairing code, so nobody else on the network can read the token
  or watch your Mirroring. Port 7380 serves the same API in plain HTTP but binds to `127.0.0.1`,
  so only the Frame itself can reach it. Set `FRAMEMATE_LISTEN=[::]:7380` to expose it on your
  LAN, and remember the token then travels in clear. Don't expose either port to the internet.
  The agent also rejects connections from public addresses outside your network, which matters
  for IPv6, where the Frame is globally addressable.
- **Developer Mode.** FrameMate doesn't depend on it. Note that while it is on, SteamOS's devkit
  service exposes Steam's debugging interface to your whole network (port 8081); FrameMate never
  uses that port.
- **Battery percentage.** FrameMate shows the percentage Steam shows. The raw value of the
  battery gauge is lower (Steam scales it), so other tools may report a different number.

## Building from source

Requirements: Rust (`rust-toolchain.toml` pins the toolchain and target), Deno, Flatpak, and for
the app the Android SDK + NDK and JDK 21. On Nix, `nix-shell` (or direnv) covers the agent and
Deno; the Android SDK/NDK and JDK are not included.

```sh
# Agent: static aarch64 binary → Flatpak bundle (no flatpak-builder or emulation needed)
scripts/flatpak.sh                  # → target/flatpak/framemate-agent.flatpak
scripts/flatpak.sh install          # build, install on the Frame via SSH, register the service

# Development loop: run the current build on the Frame without packaging
scripts/deploy.sh                   # scripts/deploy.sh logs | stop

# App
cd app
deno install
deno task tauri android build --apk --target aarch64
deno task tauri dev                   # desktop window for UI work
```

For the **iOS** build (jailbroken iOS 16) — the app for TrollStore and the notification tweak as a
`.deb` — run `scripts/ios/package.sh` on a Mac; see [`docs/iOS.md`](docs/iOS.md). It additionally
needs Xcode, Theos, `ldid`, `dpkg`, `xcodegen` and ImageMagick.

`scripts/*.sh` reach the Frame as `steamos@frame.local` (override with `FRAME_HOST`).

### Agent API

| Endpoint | |
|---|---|
| `GET /api/state` | full state as JSON |
| `GET /api/ws` | the same, pushed on every change |
| `GET /api/stream/ws` | mirroring: `{codec}` header, fMP4 init segment, one fragment per frame |
| `POST /api/notify` | toast in the headset: `{app, title, body, icon}` → `{"result": "shown"}` or `"headset_asleep"` |
| `GET /healthz` | liveness, the only route without auth |

Reachable off the Frame on `https://<frame>:7381`. The agent signs its own certificate and the
app pins it by fingerprint, so other clients need to skip chain verification (`curl -k`). Plain
HTTP lives on `127.0.0.1:7380`, which only the Frame itself can reach.

Authenticate with `?token=<token>` or `Authorization: Bearer <token>`.

## iOS Support (this fork)

This fork adds iOS support for **jailbroken iOS 16**, with the same features as Android:

- **The app** is the same Tauri app (Svelte UI, pinned-TLS pairing, mirroring), built for iOS and
  installed with **TrollStore**. Everything from the feature list works.
- **Mirroring** uses the same stream from the agent. iPhones before iOS 17.1 can't play it the
  way Android does (no Media Source Extensions), so there the app decodes the H.264 itself with
  WebCodecs, which needs iOS 16.4 or newer.
- **Notifications in VR**: iOS has no public way to read other apps' notifications, so forwarding
  is a **SpringBoard tweak** (Theos/Logos, plain Objective-C), modelled on
  [ForwardNotifier](https://github.com/Greg0109/ForwardNotifier). It sends each notification to the
  Frame over the same pinned TLS (`POST /api/notify`) and reads the same settings the app writes, so
  the bell and the per-app switches work as on Android. As on Android, an app appears in the list
  once it has sent a notification, and every app is forwarded unless you switch it off.

Tested on an iPhone with iOS 16.4.1 (rootless jailbreak) against a Steam Frame: pairing, the
dashboard, mirroring and notifications in VR. Architecture, build and install details, and what the
iOS-specific workarounds are for, are in [`docs/iOS.md`](docs/iOS.md).

## Changes in this fork

Relative to [`nailuj05/framemate`](https://github.com/nailuj05/framemate):

- **iOS app:** the Tauri iOS project (`app/src-tauri/gen/apple`), iOS Tauri commands in
  `app/src-tauri/src/lib.rs` (notification settings; stretching the webview over the whole screen),
  and the `app/src/lib/native.ts` platform bridge so the UI talks to Android's bridge or to Tauri.
- **Mirroring:** a WebCodecs player for browsers without Media Source Extensions
  (`app/src/lib/fmp4.ts`, `app/src/routes/view/+page.svelte`). Where MSE exists — Android, desktop —
  the original player is used unchanged.
- **Shared Rust:** pairing, pinned TLS and forwarding moved into `app/src-tauri/core`
  (`framemate-core`), with the forwarding preferences (`prefs`) ported from Android's
  `NotificationPrefs.kt` for the iOS app. Behaviour is unchanged.
- **Notification tweak** under `tweak/`, and iOS build/packaging scripts under `scripts/ios/`.
- **iOS app icon:** `app/src-tauri/icons/FrameMate.icon` (Apple Icon Composer), rendered into the
  iOS icon set by `scripts/ios/render-icon.sh`. It is a simplified version of the FrameMate logo
  and, like the logo, falls under §2.
- The agent, the Android app and all other artwork are upstream's, unchanged.

## Contributing

Patches and bug reports are welcome, see [`CONTRIBUTING.md`](CONTRIBUTING.md).
Commits need a `Signed-off-by` line (`git commit -s`); there's no CLA.

## License

FrameMate is free software under the **GNU General Public License v3.0 or
later** ([`LICENSE`](LICENSE)). You may use, study, share and modify it. If you
distribute it, modified or not, free or for money, you must pass on the same
freedoms and make the complete source available under the same license. Closed
forks are not permitted.

Two additional terms apply, in [`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md):
an app store distribution permission under GPL-3.0 §7, and a reservation of the
FrameMate name, logo and application identifiers (forks must use their own).

## Future

- [x] TLS Support, Cert pinning, QR pairing
- [x] iOS Support — added in this fork for jailbroken iOS 16 ([`docs/iOS.md`](docs/iOS.md))
- [ ] PWA for the mobile client
- [ ] Feed on the App notifying you of newly frame verified games (in your library)
- [ ] Control Downloads (pause, resume, reorder)
- [ ] View and Transfer Screenshots
- [x] Mobile Notifications in VR
- [ ] Turn off controller, headset, etc. 

## AI usage

This project used AI for reversing the Steam API (for use in the agent), the frontend of the mobile app, the shell scripts and the Actions used for building the releases.
AI was also used for exploring how the Video Stream for Mirroring could be accessed and encoded.

The iOS port added in this fork — the Tauri iOS client glue, the `framemate-core`
Rust crate, the SpringBoard tweak and the `scripts/ios/` build and packaging — was written with AI
assistance.

## Credits

- Icons: [Material Symbols](https://github.com/google/material-design-icons) (Apache-2.0); see
  [`app/src/lib/icons/LICENSES.md`](app/src/lib/icons/LICENSES.md).
- Steam Frame Controller Icons: [Kenney Input Prompts](https://kenney.nl/assets/input-prompts) (CC0)
- Game artwork is loaded from Steam's public CDN.
- FrameMate Icon made by the original author (reserved — see [`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md) §2).
  The iOS app icon in this fork is a simplified version of it.
- iOS notification tweak modelled on [ForwardNotifier](https://github.com/Greg0109/ForwardNotifier) by Greg0109 (GPL-3.0).

FrameMate is not affiliated with or endorsed by Valve. Steam, SteamOS and Steam Frame are trademarks of
Valve Corporation.
