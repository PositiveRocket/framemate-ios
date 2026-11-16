// The shared logic (pairing, pinned-TLS proxy, notification forwarding, forwarding prefs) lives in
// the `framemate-core` crate so the iOS notification tweak can use it too. Re-exported here so the
// integration tests (and the rest of this crate) keep referring to `framemate_app_lib::proxy` etc.
pub use framemate_core::{forward, pairing, prefs, proxy, store};

// JNI entry point for the Android notification listener.
#[cfg(target_os = "android")]
mod jni_glue;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{Manager, State};

use pairing::Pairing;

/// connection from frontend -> proxy -> agent, secret is for proxy so no other android app can connect
#[derive(Serialize)]
struct Connection {
    port: u16,
    secret: String,
    token: String,
    paired: bool,
}

struct App {
    current: proxy::Current,
    status: Arc<proxy::Status>,
    proxy: Mutex<Option<proxy::Proxy>>,
    /// `pairing.json` lives here.
    store: PathBuf,
    /// The directory holding the pairing and the forwarding preferences. On iOS it is shared with
    /// the SpringBoard tweak; the notification commands below read and write it.
    config_dir: PathBuf,
}

/// Takes a lock, ignoring poisoning: a panicked relay task must not leave the app permanently
/// unable to report its own connection details. Everything guarded here is plain data.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

impl App {
    fn connection(&self) -> Option<Connection> {
        let proxy = lock(&self.proxy);
        let proxy = proxy.as_ref()?;
        let current = lock(&self.current);
        Some(Connection {
            port: proxy.port,
            secret: proxy.secret.clone(),
            token: current.as_ref().map(|t| t.token()).unwrap_or_default(),
            paired: current.is_some(),
        })
    }
}

#[tauri::command]
fn connection(app: State<'_, App>) -> Option<Connection> {
    app.connection()
}

/// Accept scanned pairing payload, or one typed in by hand.
#[tauri::command]
fn pair(payload: String, app: State<'_, App>) -> Result<Connection, String> {
    let pairing = Pairing::parse(payload.trim())?;
    // Built before it is stored, so a pairing that can't be used never reaches the disk.
    let target = proxy::Target::new(pairing.clone())?;
    pairing::store(&app.store, &pairing)?;
    *lock(&app.current) = Some(target);
    app.connection().ok_or_else(|| "the local proxy isn't running".to_owned())
}

/// A failure the user has to act on
#[tauri::command]
fn last_error(app: State<'_, App>) -> Option<String> {
    app.status.take()
}

// --- Phone notifications (iOS).
//
// On Android these settings live in Kotlin (NotificationPrefs.kt), reached through the WebView
// bridge, because the listener service runs without the WebView. iOS has no WebView bridge in the
// generated app, so the settings UI talks to these Tauri commands instead; they share the prefs
// file with the SpringBoard tweak. On desktop they are harmless no-ops the UI never calls.

/// `{enabled, apps: [...], last: {...} | null}` — the `NotificationSettings` the settings page reads.
#[tauri::command]
fn notification_settings(app: State<'_, App>) -> String {
    prefs::to_json(&app.config_dir)
}

#[tauri::command]
fn set_notifications_enabled(enabled: bool, app: State<'_, App>) {
    prefs::set_enabled(&app.config_dir, enabled);
}

#[tauri::command]
fn set_notification_app_enabled(pkg: String, enabled: bool, app: State<'_, App>) {
    prefs::set_app_enabled(&app.config_dir, &pkg, enabled);
}

/// Whether the FrameMate SpringBoard tweak is installed (its dylib is present at a known path).
/// Always false off iOS.
#[tauri::command]
fn notification_access_granted() -> bool {
    #[cfg(target_os = "ios")]
    {
        const PATHS: &[&str] = &[
            "/var/jb/usr/lib/TweakInject/FrameMate.dylib", // rootless (ElleKit)
            "/usr/lib/TweakInject/FrameMate.dylib",        // rootful (ElleKit)
            "/Library/MobileSubstrate/DynamicLibraries/FrameMate.dylib", // rootful (Substrate)
        ];
        PATHS.iter().any(|p| std::path::Path::new(p).exists())
    }
    #[cfg(not(target_os = "ios"))]
    {
        false
    }
}

/// Fires a test toast and returns at once; the outcome lands in `notification_settings().last`,
/// which the UI polls (the send blocks on the network for up to ~15 s).
#[tauri::command]
fn send_test_notification(app: State<'_, App>) {
    let dir = app.config_dir.clone();
    tauri::async_runtime::spawn_blocking(move || {
        forward::send_test(&dir);
    });
}

/// iOS grants LAN access through a one-time system prompt the first time the app connects; there
/// is no API to query it, so the UI assumes it is allowed (unlike Android's explicit permission).
#[tauri::command]
fn local_network_allowed() -> bool {
    true
}

/// Where the pairing and preferences live. On iOS it is `Documents/FrameMate` inside the app's
/// sandbox container — the same directory the SpringBoard tweak finds from the app's container URL
/// (see `framemate_core::store`). The container keeps WKWebView working; a world-writable path
/// outside it would need entitlements that break the webview. Everywhere else: the app's own
/// config directory.
fn config_dir(app: &tauri::App) -> Result<PathBuf, Box<dyn std::error::Error>> {
    #[cfg(target_os = "ios")]
    {
        let _ = app;
        // The app's container root (NSHomeDirectory) is exactly the tweak's
        // LSApplicationProxy.dataContainerURL, so `$HOME/Documents/FrameMate` is the one path both
        // sides compute identically.
        let home = std::env::var("HOME").map_err(|_| "HOME is not set")?;
        Ok(PathBuf::from(home).join("Documents").join(store::DIR_NAME))
    }
    #[cfg(not(target_os = "ios"))]
    {
        Ok(app.path().app_config_dir()?)
    }
}

/// Applies `fill_the_screen` again; the page calls it once it has loaded, in case the first pass
/// came before WebKit's own first layout.
#[tauri::command]
fn refit_webview(webview: tauri::Webview) {
    #[cfg(target_os = "ios")]
    fill_the_screen(&webview);
    #[cfg(not(target_os = "ios"))]
    let _ = webview;
}

#[cfg(target_os = "ios")]
mod geometry {
    use objc2::encode::{Encode, Encoding};

    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Point {
        pub x: f64,
        pub y: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Size {
        pub width: f64,
        pub height: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Rect {
        pub origin: Point,
        pub size: Size,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Insets {
        pub top: f64,
        pub left: f64,
        pub bottom: f64,
        pub right: f64,
    }
    unsafe impl Encode for Point {
        const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
    }
    unsafe impl Encode for Size {
        const ENCODING: Encoding = Encoding::Struct("CGSize", &[f64::ENCODING, f64::ENCODING]);
    }
    unsafe impl Encode for Rect {
        const ENCODING: Encoding = Encoding::Struct("CGRect", &[Point::ENCODING, Size::ENCODING]);
    }
    unsafe impl Encode for Insets {
        const ENCODING: Encoding =
            Encoding::Struct("UIEdgeInsets", &[f64::ENCODING, f64::ENCODING, f64::ENCODING, f64::ENCODING]);
    }
}

/// Lets the page lay itself out over the whole screen, under the status bar and the home
/// indicator: the WKWebView is stretched over its whole parent view, and its scroll view stops
/// insetting the page by the safe area (which would leave a dead strip at the bottom and make
/// `env(safe-area-inset-*)` report zero). The page pads its own top bar and tab bar by those
/// insets (`viewport-fit=cover`).
#[cfg(target_os = "ios")]
fn fill_the_screen(webview: &tauri::Webview) {
    let _ = webview.with_webview(fit_webview);
}

/// The work of `fill_the_screen`, on the native WKWebView.
#[cfg(target_os = "ios")]
fn fit_webview(platform: tauri::webview::PlatformWebview) {
    use geometry::{Insets, Rect};
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    /// `UIScrollViewContentInsetAdjustmentNever`
    const NEVER: isize = 2;
    /// `UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight`
    const FLEXIBLE_SIZE: usize = (1 << 1) | (1 << 4);
    unsafe {
        let wk = platform.inner() as *mut AnyObject;
        if wk.is_null() {
            return;
        }
        let parent: *mut AnyObject = msg_send![wk, superview];
        let window: *mut AnyObject = msg_send![wk, window];
        let scroll_view: *mut AnyObject = msg_send![wk, scrollView];

        let _ = window;
        if !scroll_view.is_null() {
            let _: () = msg_send![scroll_view, setContentInsetAdjustmentBehavior: NEVER];
            let _: () = msg_send![scroll_view, setContentInset: Insets::default()];
        }
        // WebKit sizes the page's viewport from the safe area when the webview is laid out, and
        // doesn't redo it when the inset behaviour changes afterwards (the page stayed 845 pt
        // tall on a 926 pt screen). A real change of frame makes it re-measure: shrink by a
        // point, lay out, and restore.
        if !parent.is_null() {
            let full: Rect = msg_send![parent, bounds];
            let mut nudged = full;
            nudged.size.height -= 1.0;
            let _: () = msg_send![wk, setFrame: nudged];
            let _: () = msg_send![wk, layoutIfNeeded];
            let _: () = msg_send![wk, setFrame: full];
            let _: () = msg_send![wk, setAutoresizingMask: FLEXIBLE_SIZE];
            let _: () = msg_send![wk, layoutIfNeeded];
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    #[cfg(mobile)]
    let builder = builder.plugin(tauri_plugin_barcode_scanner::init());
    // The system browser / iOS Settings, from `openExternal` and the settings page.
    let builder = builder.plugin(tauri_plugin_opener::init());
    // Applied when a page starts loading, i.e. before its first layout, and again whenever one
    // finishes; setting it twice is harmless.
    #[cfg(target_os = "ios")]
    let builder = builder.on_page_load(|webview, _payload| fill_the_screen(webview));
    builder
        .invoke_handler(tauri::generate_handler![
            connection,
            pair,
            last_error,
            notification_settings,
            set_notifications_enabled,
            set_notification_app_enabled,
            notification_access_granted,
            send_test_notification,
            local_network_allowed,
            refit_webview,
        ])
        .setup(|app| {
            let dir = config_dir(app)?;
            let store = store::pairing_path(&dir);
            let current: proxy::Current = Arc::new(Mutex::new(
                pairing::load(&store).and_then(|p| proxy::Target::new(p).ok()),
            ));
            let status = Arc::new(proxy::Status::default());
            let state = App {
                current: current.clone(),
                status: status.clone(),
                proxy: Mutex::new(None),
                store,
                config_dir: dir,
            };
            app.manage(state);

            // As early as possible: before the first page load, so WebKit's first layout already
            // uses the whole screen (see `fill_the_screen`; it runs again on every page load).
            #[cfg(target_os = "ios")]
            for window in app.webview_windows().values() {
                let _ = window.with_webview(fit_webview);
            }

            // Bound before the WebView can ask for the port. Only the bind is awaited; the accept loop runs on its own task.
            match tauri::async_runtime::block_on(proxy::spawn(current, status)) {
                Ok(proxy) => *lock(&app.state::<App>().proxy) = Some(proxy),
                Err(e) => eprintln!("framemate: local proxy failed to start: {e}"),
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
