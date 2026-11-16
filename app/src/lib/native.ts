// One place for the things the web layer can't do itself, abstracted over the platform:
//   * Android talks to the WebView bridge (`window.FrameMateAndroid`, from MainActivity.kt),
//   * iOS talks to Tauri commands (src-tauri/src/lib.rs) and the opener plugin, because the
//     generated iOS app has no WebView bridge,
//   * a plain browser (desktop/dev) falls back where it can.
//
// Everything notification-related ends up at the same shared prefs file on each platform, so the
// settings UI and the notification source (the Android listener service / the iOS SpringBoard
// tweak) always agree.

import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";

export type Platform = "android" | "ios" | "web";

const android = () => (typeof window !== "undefined" ? window.FrameMateAndroid : undefined);
const hasTauri = () => typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export function platform(): Platform {
  if (android()?.notificationSettings) return "android";
  if (hasTauri() && typeof navigator !== "undefined" && /iPhone|iPad|iPod/.test(navigator.userAgent)) {
    return "ios";
  }
  return "web";
}

export const isIOS = () => platform() === "ios";

// --- Phone notifications ---

/** Whether phone-notification forwarding exists on this platform at all. */
export function notificationsSupported(): boolean {
  return platform() !== "web";
}

/** The `NotificationSettings` JSON (`{enabled, apps, last}`), or null where unsupported. */
export async function getNotificationSettings(): Promise<string | null> {
  const a = android();
  if (a?.notificationSettings) return a.notificationSettings();
  if (isIOS()) return invoke<string>("notification_settings");
  return null;
}

/** Android: "Notification access" granted. iOS: the SpringBoard tweak is installed. */
export async function notificationAccessGranted(): Promise<boolean> {
  const a = android();
  if (a?.notificationAccessGranted) return a.notificationAccessGranted();
  if (isIOS()) return invoke<boolean>("notification_access_granted");
  return false;
}

export async function setNotificationsEnabled(enabled: boolean): Promise<void> {
  const a = android();
  if (a?.setNotificationsEnabled) {
    a.setNotificationsEnabled(enabled);
    return;
  }
  if (isIOS()) await invoke("set_notifications_enabled", { enabled });
}

export async function setNotificationApp(pkg: string, enabled: boolean): Promise<void> {
  const a = android();
  if (a?.setNotificationAppEnabled) {
    a.setNotificationAppEnabled(pkg, enabled);
    return;
  }
  if (isIOS()) await invoke("set_notification_app_enabled", { pkg, enabled });
}

export async function sendTestNotification(): Promise<void> {
  const a = android();
  if (a?.sendTestNotification) {
    a.sendTestNotification();
    return;
  }
  if (isIOS()) await invoke("send_test_notification");
}

/**
 * Android opens the system "Notification access" page. iOS has no such page — access *is* the
 * tweak being installed — so there is nothing to open there.
 */
export function openNotificationAccessSettings(): void {
  android()?.openNotificationAccessSettings?.();
}

// --- Other native UI ---

/** Opens a URL in the system browser. */
export function openExternalUrl(url: string): void {
  const a = android();
  if (a?.openUrl) {
    a.openUrl(url);
    return;
  }
  if (hasTauri()) {
    openUrl(url).catch(() => {});
    return;
  }
  window.open(url, "_blank", "noopener");
}

/** Opens this app's page in the system Settings app. */
export function openAppSettings(): void {
  const a = android();
  if (a?.openAppSettings) {
    a.openAppSettings();
    return;
  }
  if (isIOS()) openUrl("app-settings:").catch(() => {});
}
