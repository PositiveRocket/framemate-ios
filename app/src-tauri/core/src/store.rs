//! Where the pairing and the forwarding preferences live on disk.
//!
//! Each caller passes in its directory; this module only names the two files inside it.
//!
//! On iOS the app and the SpringBoard tweak are two processes that share these files, but they
//! cannot be world-writable: the app needs a normal sandbox container for WKWebView to work, so it
//! keeps them inside that container (`<container>/Documents/FrameMate`, resolved through the Tauri
//! path API in `lib.rs`). The tweak, which runs inside SpringBoard, finds the very same directory
//! at runtime from the app's container URL (LSApplicationProxy; see `tweak/Tweak.xm`). On Android
//! each caller already knows its own data dir.
//!
//! Nothing here stores notification *content*: only the pairing, the apps the user has seen/picked,
//! and the status of the last send.

use std::path::{Path, PathBuf};

/// The subdirectory name both sides agree on, inside whatever base directory each resolves (the
/// app's `Documents` on iOS, the data dir on Android).
pub const DIR_NAME: &str = "FrameMate";

/// `pairing.json` inside `dir`.
pub fn pairing_path(dir: &Path) -> PathBuf {
    dir.join("pairing.json")
}

/// `notifications.json` inside `dir` (the forwarding preferences).
pub fn prefs_path(dir: &Path) -> PathBuf {
    dir.join("notifications.json")
}
