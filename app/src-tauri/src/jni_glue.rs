//! JNI entry point for the Android notification listener.
//!
//! `dev.framemate.app.NotificationBridge.send(dataDir, json)` → `framemate_core::forward::send`.
//! The Kotlin side passes its own data dir and records the result itself, so this stays a thin
//! blocking shim.

use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::jstring;

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_framemate_app_NotificationBridge_send<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    data_dir: JString<'local>,
    json: JString<'local>,
) -> jstring {
    let result = match (env.get_string(&data_dir), env.get_string(&json)) {
        (Ok(dir), Ok(json)) => {
            let (dir, json): (String, String) = (dir.into(), json.into());
            framemate_core::forward::send(std::path::Path::new(&dir), &json)
        }
        _ => "error: bad arguments".into(),
    };
    env.new_string(result).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}
