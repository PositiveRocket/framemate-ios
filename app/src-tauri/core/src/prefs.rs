//! Forwarding preferences: the master switch, which apps are forwarded, the apps seen so far and
//! the status of the last send. Ported from the Android `NotificationPrefs.kt`.
//!
//! On Android this was `SharedPreferences`, read by both the listener service and the WebView.
//! Here it is a JSON file ([`crate::store::prefs_path`]) read and written by two processes on
//! iOS — the SpringBoard tweak (its own Objective-C reader/writer of this same JSON, see
//! `tweak/Tweak.xm`) and the FrameMate app — so every change is a reload-modify-write and each
//! save is atomic (write a temp file, then rename). Keep the field names in step with the tweak.
//! Nothing here stores notification content, only app identifiers, their labels and the last send
//! status.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Default, Serialize, Deserialize)]
pub struct Prefs {
    /// The bell. Off by default; the opt-in for the whole feature.
    #[serde(default)]
    pub enabled: bool,
    /// Apps switched off individually. Everything seen is forwarded unless listed here.
    #[serde(default)]
    pub disabled_apps: BTreeSet<String>,
    /// Apps that have posted a notification since forwarding was set up, so the user can pick
    /// them: bundle id -> display label.
    #[serde(default)]
    pub seen: BTreeMap<String, String>,
    /// Outcome of the last send (`shown`, `headset_asleep`, `rate_limited`, `not_paired`,
    /// `error: …`), and when, in epoch milliseconds.
    #[serde(default)]
    pub last_result: Option<String>,
    #[serde(default)]
    pub last_time: u64,
}

impl Prefs {
    /// Every app is forwarded unless switched off; the bell (`enabled`) is the opt-in.
    pub fn is_app_enabled(&self, pkg: &str) -> bool {
        !self.disabled_apps.contains(pkg)
    }
}

/// Loads the preferences, or the defaults (everything off, nothing seen) when the file is absent
/// or unreadable.
pub fn load(dir: &Path) -> Prefs {
    std::fs::read(crate::store::prefs_path(dir))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// Writes the preferences atomically (temp file + rename) so a concurrent reader never sees a
/// half-written file. Creates the directory on first write.
pub fn save(dir: &Path, prefs: &Prefs) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let path = crate::store::prefs_path(dir);
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_vec(prefs).map_err(std::io::Error::other)?;
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, &path)
}

/// Reload, mutate, save. The window between the read and the write is tiny; a lost update across
/// the two processes would at worst drop one "app seen" or one "last result", never corrupt the
/// file. Returns whatever the mutation returns.
fn update<T>(dir: &Path, f: impl FnOnce(&mut Prefs) -> T) -> T {
    let mut prefs = load(dir);
    let out = f(&mut prefs);
    let _ = save(dir, &prefs);
    out
}

pub fn enabled(dir: &Path) -> bool {
    load(dir).enabled
}

pub fn set_enabled(dir: &Path, enabled: bool) {
    update(dir, |p| p.enabled = enabled);
}

pub fn set_app_enabled(dir: &Path, pkg: &str, enabled: bool) {
    update(dir, |p| {
        if enabled {
            p.disabled_apps.remove(pkg);
        } else {
            p.disabled_apps.insert(pkg.to_owned());
        }
    });
}

/// The bell is on *and* this app isn't switched off. The gate the tweak checks per notification.
pub fn should_forward(dir: &Path, pkg: &str) -> bool {
    let p = load(dir);
    p.enabled && p.is_app_enabled(pkg)
}

/// Records an app the user can later pick. Cheap no-op when the label hasn't changed.
pub fn remember_app(dir: &Path, pkg: &str, label: &str) {
    // Avoid the write (and its rename) when nothing changed: notifications are frequent.
    if load(dir).seen.get(pkg).map(String::as_str) == Some(label) {
        return;
    }
    update(dir, |p| {
        p.seen.insert(pkg.to_owned(), label.to_owned());
    });
}

pub fn record_result(dir: &Path, result: &str) {
    update(dir, |p| {
        p.last_result = Some(result.to_owned());
        p.last_time = now_ms();
    });
}

/// For the settings page: `{enabled, apps: [{pkg, label, enabled}], last: {result, time} | null}`.
/// Apps are sorted by label, case-insensitively, as on Android.
pub fn to_json(dir: &Path) -> String {
    let p = load(dir);
    let mut apps: Vec<_> = p.seen.iter().collect();
    apps.sort_by_key(|(_, label)| label.to_lowercase());
    let apps: Vec<_> = apps
        .into_iter()
        .map(|(pkg, label)| {
            serde_json::json!({ "pkg": pkg, "label": label, "enabled": p.is_app_enabled(pkg) })
        })
        .collect();
    let last = p
        .last_result
        .as_ref()
        .map(|result| serde_json::json!({ "result": result, "time": p.last_time }));
    serde_json::json!({ "enabled": p.enabled, "apps": apps, "last": last }).to_string()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        // A dir per test: the tests run in one process and would otherwise share these files.
        let dir = std::env::temp_dir().join(format!("framemate-prefs-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn defaults_to_off_and_empty() {
        let dir = tmp("defaults");
        assert!(!enabled(&dir));
        assert!(!should_forward(&dir, "com.example.app"));
        let v: serde_json::Value = serde_json::from_str(&to_json(&dir)).unwrap();
        assert_eq!(v["enabled"], false);
        assert_eq!(v["apps"].as_array().unwrap().len(), 0);
        assert!(v["last"].is_null());
    }

    #[test]
    fn master_switch_gates_every_app() {
        let dir = tmp("master");
        remember_app(&dir, "com.example.chat", "Chat");
        assert!(!should_forward(&dir, "com.example.chat")); // bell off
        set_enabled(&dir, true);
        assert!(should_forward(&dir, "com.example.chat"));
        set_app_enabled(&dir, "com.example.chat", false);
        assert!(!should_forward(&dir, "com.example.chat")); // this app off
        assert!(should_forward(&dir, "com.other.app")); // but others still go
    }

    #[test]
    fn remembers_and_sorts_apps_and_last_result() {
        let dir = tmp("remember");
        remember_app(&dir, "com.b", "Zebra");
        remember_app(&dir, "com.a", "apple");
        set_app_enabled(&dir, "com.b", false);
        record_result(&dir, "shown");
        let v: serde_json::Value = serde_json::from_str(&to_json(&dir)).unwrap();
        let apps = v["apps"].as_array().unwrap();
        assert_eq!(apps[0]["label"], "apple"); // case-insensitive sort
        assert_eq!(apps[1]["label"], "Zebra");
        assert_eq!(apps[1]["enabled"], false);
        assert_eq!(v["last"]["result"], "shown");
        assert!(v["last"]["time"].as_u64().unwrap() > 0);
    }
}
