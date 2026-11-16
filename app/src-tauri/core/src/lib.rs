//! FrameMate shared core.
//!
//! Everything here is platform-agnostic and used by the Tauri app (`app/src-tauri`) on every
//! platform. The iOS notification tweak (`tweak/Tweak.xm`) is separate Objective-C, but shares the
//! on-disk formats of [`pairing`] and [`prefs`] and the pin formula in [`proxy`]: change those
//! here and the tweak has to follow.
//!
//! The pieces:
//!   * [`pairing`] – the scanned pairing payload and its on-disk form.
//!   * [`proxy`]   – pinned TLS to the Frame and the loopback proxy the WebView talks through.
//!   * [`forward`] – sending one notification to the Frame (`POST /api/notify`).
//!   * [`prefs`]   – which apps are forwarded and the last send result (ported from the Android
//!                   `NotificationPrefs.kt`); shared by the listener and the settings UI.
//!   * [`store`]   – where the pairing and preferences live on disk.

pub mod forward;
pub mod pairing;
pub mod prefs;
pub mod proxy;
pub mod store;
