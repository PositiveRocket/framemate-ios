//! Phone notifications → toast in the headset (`POST /api/notify` on the agent).
//!
//! The entry point is platform-agnostic. It reads the pairing straight from disk and talks pinned
//! TLS itself (reusing [`crate::proxy`]), so it works without the app window, the WebView or the
//! loopback proxy being up — which matters because the notification source runs on its own:
//!   * on Android, a `NotificationListenerService` calls [`send`] through JNI (glue lives in the
//!     app crate),
//!   * on iOS, the app's "send a test notification" uses it; real notifications are sent by the
//!     SpringBoard tweak's own Objective-C implementation of the same request (`tweak/Tweak.xm`).

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use crate::pairing::{self, Pairing};
use crate::proxy::Target;
use crate::store;

/// The last target, kept so the address that worked (mDNS name or IP) is tried first next time.
static TARGET: Mutex<Option<(Pairing, std::sync::Arc<Target>)>> = Mutex::new(None);

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Sends one toast. `config_dir` holds `pairing.json`; returns a short status word (`shown`,
/// `headset_asleep`, `rate_limited`, `not_paired`, or `error: …`). Blocks for up to ~15 s; never
/// call it on a UI thread.
pub fn send(config_dir: &Path, json: &str) -> String {
    let Some(pairing) = pairing::load(&store::pairing_path(config_dir)) else {
        return "not_paired".into();
    };
    let target = {
        let mut cached = TARGET.lock().unwrap_or_else(|e| e.into_inner());
        match cached.as_ref() {
            Some((p, target)) if *p == pairing => target.clone(),
            _ => match Target::new(pairing.clone()) {
                Ok(target) => {
                    let target = std::sync::Arc::new(target);
                    *cached = Some((pairing, target.clone()));
                    target
                }
                Err(e) => return format!("error: {e}"),
            },
        }
    };
    match runtime().block_on(target.post_json("/api/notify", json)) {
        Ok((200, body)) => serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| v["result"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "error: unexpected answer from the Frame".into()),
        Ok((401, _)) => "error: the Frame rejected the token, pair again".into(),
        Ok((429, _)) => "rate_limited".into(),
        // Agents before v0.3.0 have no /api/notify.
        Ok((404, _)) => "error: the FrameMate agent on the Frame is too old for notifications, update it".into(),
        Ok((status, body)) => format!("error: {status} {body}"),
        Err(e) => format!("error: {e}"),
    }
}

/// [`send`], then store the outcome in the preferences so the settings page can show it. This is
/// what the iOS app's "send test" uses; the Android side records the result itself
/// (in Kotlin) after [`send`] returns.
pub fn send_and_record(config_dir: &Path, json: &str) -> String {
    let result = send(config_dir, json);
    crate::prefs::record_result(config_dir, &result);
    result
}

/// The master-switch-aware test toast, sent the same way a real notification would be. Returns
/// `disabled` without sending when the bell is off, matching the Android `sendTest`.
pub fn send_test(config_dir: &Path) -> String {
    if !crate::prefs::enabled(config_dir) {
        crate::prefs::record_result(config_dir, "disabled");
        return "disabled".into();
    }
    let json = serde_json::json!({
        "app": "FrameMate",
        "title": "FrameMate",
        "body": "Notifications from your phone will show up like this.",
    })
    .to_string();
    send_and_record(config_dir, &json)
}

#[cfg(test)]
mod tests {
    #[test]
    fn reports_a_missing_pairing() {
        let dir = std::env::temp_dir().join("framemate-forward-test-empty");
        let _ = std::fs::create_dir_all(&dir);
        assert_eq!(super::send(&dir, "{}"), "not_paired");
    }
}
