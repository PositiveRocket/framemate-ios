// Phone notifications as toasts in the headset. The settings live on the native side (Android:
// NotificationPrefs.kt; iOS: the shared prefs file via Tauri commands) because the notification
// source runs without the WebView — the Android listener service, the iOS SpringBoard tweak. This
// mirrors them for the top bar's bell and the Settings page.

import * as native from "$lib/native";

export interface NotificationSettings {
  /** The bell: off by default, and quick to switch off when someone else wears the headset. */
  enabled: boolean;
  /** Apps that posted a notification so far; all forwarded unless switched off. */
  apps: { pkg: string; label: string; enabled: boolean }[];
  /** Outcome of the last send: shown, headset_asleep, rate_limited, not_paired, error: … */
  last: { result: string; time: number } | null;
  /** iOS: forwarding paused because the Frame wasn't reachable (set by the tweak). */
  paused?: { since: number } | null;
}

class Notifications {
  readonly supported = native.notificationsSupported();
  readonly platform = native.platform();
  settings = $state<NotificationSettings | null>(null);
  access = $state(false);
  testing = $state(false);

  constructor() {
    // Fire-and-forget: Settings opens its section depending on `access`, and the reactive state
    // updates the UI as soon as the native side answers.
    void this.refresh();
  }

  get enabled() {
    return this.settings?.enabled ?? false;
  }

  /** The app reached the Frame: end a pause the iOS tweak set because it couldn't. */
  async resume() {
    if (!this.settings?.paused) return;
    try {
      await native.resumeNotifications();
    } catch {}
    await this.refresh();
  }

  async refresh() {
    if (!this.supported) return;
    try {
      const json = await native.getNotificationSettings();
      if (json) this.settings = JSON.parse(json);
      this.access = await native.notificationAccessGranted();
    } catch {}
  }

  async setEnabled(enabled: boolean) {
    await native.setNotificationsEnabled(enabled);
    await this.refresh();
  }

  async setApp(pkg: string, enabled: boolean) {
    await native.setNotificationApp(pkg, enabled);
    await this.refresh();
  }

  openAccessSettings() {
    native.openNotificationAccessSettings();
  }

  async sendTest() {
    const before = this.settings?.last?.time ?? 0;
    this.testing = true;
    await native.sendTestNotification();
    // The send runs on a native thread (up to ~15 s); poll for its result.
    for (let i = 0; i < 40 && (this.settings?.last?.time ?? 0) <= before; i++) {
      await new Promise(resolve => setTimeout(resolve, 500));
      await this.refresh();
    }
    this.testing = false;
  }
}

export const notifications = new Notifications();

export function describeResult(result: string) {
  return (
    {
      shown: "Shown in the headset.",
      headset_asleep: "Delivered, but the headset is asleep, so Steam didn't show it.",
      rate_limited: "Too many at once. Try again in a few seconds.",
      not_paired: "Pair the app with your Frame first.",
      disabled: "Notifications are off. Turn them on with the bell in the top bar.",
    }[result] ?? result.replace(/^error: /, "Failed: ")
  );
}
