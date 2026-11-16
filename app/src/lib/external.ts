import { openExternalUrl } from "$lib/native";

/** Opens `url` in the system browser (Android bridge, iOS opener plugin, else a new tab). */
export function openExternal(url: string) {
  openExternalUrl(url);
}

/** onclick for `<a href>`: keeps the href, opens externally. */
export function external(event: MouseEvent) {
  event.preventDefault();
  openExternal((event.currentTarget as HTMLAnchorElement).href);
}
