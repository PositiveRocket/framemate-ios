<script lang="ts">
  // Same protocol as the agent's /stream page (JSON {codec}, fMP4 init, moof+mdat → MSE).
  // The agent only captures while someone watches, so leaving this page stops it.
  import { onDestroy, onMount } from "svelte";
  import { pushState } from "$app/navigation";
  import { page } from "$app/state";
  import { agent } from "$lib/agent.svelte";
  import { parameterSetsAnnexB, parseInit, parseSegment, sampleToAnnexB } from "$lib/fmp4";
  import { isIOS } from "$lib/native";
  import Icon from "$lib/components/Icon.svelte";
  import Row from "$lib/components/Row.svelte";
  import Section from "$lib/components/Section.svelte";

  let video: HTMLVideoElement;
  let canvas: HTMLCanvasElement;
  // True when frames are painted on the canvas (WebCodecs) instead of played by the <video>.
  let painted = $state(false);
  let status = $state("Connecting…");
  let socket: WebSocket | null = null;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let closed = false;
  let objectUrl: string | undefined;
  const stats = $derived(agent.state?.stream);
  const fullscreen = $derived(!!page.state.fullscreen);

  // Fullscreen is a shallow history entry: Android's back button (and Esc on desktop)
  // leave it like any other navigation.
  function enterFullscreen() {
    pushState("", { fullscreen: true });
  }

  function applyFullscreen(enabled: boolean) {
    if (window.FrameMateAndroid) {
      window.FrameMateAndroid.setFullscreen(enabled);
    } else if (enabled && !document.fullscreenElement) {
      document.documentElement.requestFullscreen?.().catch(() => {});
    } else if (!enabled && document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
    }
  }

  $effect(() => applyFullscreen(fullscreen));

  // Leaving browser fullscreen via Esc: drop our history entry too.
  function onFullscreenChange() {
    if (!document.fullscreenElement && page.state.fullscreen) history.back();
  }

  /** Where the stream's binary messages go: the init segment first, then one segment per frame. */
  interface Sink {
    push(data: ArrayBuffer): void;
    close(): void;
  }

  // The usual path: hand the fMP4 stream to the <video> element through Media Source Extensions.
  // iPadOS and iOS 17.1+ only have the "managed" flavour, which works the same for our purposes.
  function mediaSourceSink(Source: typeof MediaSource, type: string): Sink {
    let buffer: SourceBuffer | null = null;
    const queue: ArrayBuffer[] = [];
    const pump = () => {
      if (buffer && !buffer.updating && queue.length) buffer.appendBuffer(queue.shift()!);
    };
    const source = new Source();
    if (objectUrl) URL.revokeObjectURL(objectUrl); // previous connection's source
    objectUrl = URL.createObjectURL(source);
    video.disableRemotePlayback = true; // required for ManagedMediaSource; harmless otherwise
    video.src = objectUrl;
    source.addEventListener(
      "sourceopen",
      () => {
        buffer = source.addSourceBuffer(type);
        buffer.mode = "sequence";
        buffer.addEventListener("updateend", () => {
          keepLive(buffer!);
          pump();
        });
        pump();
      },
      { once: true },
    );
    return {
      push(data) {
        queue.push(data);
        pump();
      },
      close() {},
    };
  }

  // iPhones before iOS 17.1 have no Media Source Extensions at all, so there the frames are
  // taken out of the container (lib/fmp4.ts), decoded with WebCodecs (iOS 16.4+) and painted
  // on a canvas. `failed` asks for a fresh connection, which starts with a new keyframe.
  const MAX_QUEUED_FRAMES = 30;

  // How the H.264 goes in: with the avcC record as `description` and length-prefixed samples
  // (the container's own form), or as an Annex B stream with no description. Decoders differ in
  // which one they accept, so a decoder that fails before showing a single frame makes the next
  // connection try the other form. Remembered while the app runs.
  const MODES = ["avc", "annexb"] as const;
  type Mode = (typeof MODES)[number];
  const MODE_KEY = "framemate.mirrorDecodeMode";
  function savedMode(): number {
    try {
      const index = MODES.indexOf(localStorage.getItem(MODE_KEY) as Mode);
      return index < 0 ? 0 : index;
    } catch {
      return 0;
    }
  }
  let modeIndex = savedMode();
  /** Connections in a row that failed before the first frame. */
  let failedStarts = 0;

  function decoderSink(codec: string, failed: () => void): Sink {
    const mode: Mode = MODES[modeIndex % MODES.length];
    const context = canvas.getContext("2d");
    let decoder: VideoDecoder | null = null;
    let decoderConfig: VideoDecoderConfig | null = null;
    let timescale = 90_000;
    // Deltas are useless until a keyframe has gone in; also set again after skipping frames.
    let needKeyframe = true;
    let decoded = 0;
    let sent = 0;
    let parameterSets: Uint8Array | null = null;
    /** When the decoder last produced a frame, and how many had been sent by then. */
    let sentAtLastOutput = 0;
    let lastOutputAt = performance.now();
    /** Bitmap copies still being made; frames beyond a few are dropped rather than queued. */
    let converting = 0;
    // iOS 16.4's decoder hands out frames from a small pool, and a frame drawn straight onto a
    // canvas keeps its buffer busy: after ~120 frames the decoder silently stops. So each frame
    // is copied into an ImageBitmap, released at once, and the copy is drawn.
    let viaBitmap = typeof createImageBitmap === "function";

    function draw(source: CanvasImageSource, width: number, height: number) {
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      try {
        context?.drawImage(source, 0, 0);
      } catch (e) {
        // A frame that can't be drawn is skipped; the next one replaces it anyway.
      }
    }

    function show(frame: VideoFrame) {
      const width = frame.displayWidth;
      const height = frame.displayHeight;
      if (!viaBitmap) {
        draw(frame, width, height);
        frame.close();
        return;
      }
      if (converting >= 3) {
        frame.close();
        return;
      }
      converting++;
      createImageBitmap(frame)
        .then(bitmap => {
          frame.close();
          draw(bitmap, width, height);
          bitmap.close();
        })
        .catch(() => {
          viaBitmap = false; // no bitmap copies here: draw frames directly from now on
          draw(frame, width, height);
          frame.close();
        })
        .finally(() => converting--);
    }

    function makeDecoder() {
      sentAtLastOutput = sent;
      lastOutputAt = performance.now();
      decoder = new VideoDecoder({
        output: frame => {
          decoded++;
          sentAtLastOutput = sent;
          lastOutputAt = performance.now();
          if (decoded === 1) {
            failedStarts = 0;
            try {
              localStorage.setItem(MODE_KEY, mode);
            } catch {
              // not remembered; the next visit just tries again
            }
          }
          show(frame);
        },
        error: () => {
          if (decoded === 0) {
            failedStarts++;
            modeIndex++;
          }
          failed();
        },
      });
      decoder.configure(decoderConfig!);
    }

    // Safety net: frames keep going in but none have come out for a while — the decoder has
    // stalled without an error. Replace it and resume at the next keyframe.
    const watchdog = setInterval(() => {
      if (!decoder || decoder.state !== "configured" || decoded === 0) return;
      if (sent - sentAtLastOutput < 10 || performance.now() - lastOutputAt < 1500) return;
      try {
        decoder.close();
      } catch {
        // already closed
      }
      needKeyframe = true;
      makeDecoder();
    }, 500);

    return {
      push(data) {
        const bytes = new Uint8Array(data);
        if (!decoder) {
          const config = parseInit(bytes);
          if (!config) return;
          timescale = config.timescale;
          // Own copies: WebKit 16.4's WebCodecs mishandles views into a larger buffer.
          const description = config.description.slice();
          parameterSets = parameterSetsAnnexB(description);
          decoderConfig =
            mode === "avc"
              ? { codec, description, optimizeForLatency: true }
              : { codec, optimizeForLatency: true };
          makeDecoder();
          return;
        }
        if (decoder.state !== "configured") return;
        const samples = parseSegment(bytes);
        for (const sample of samples) {
          // Fallen about a second behind (a slow moment, or just back from the background):
          // drop the rest of this group of pictures and pick up at the next keyframe, rather
          // than show the past. Generous, because the first frames queue up while the decoder
          // is still starting.
          if (decoder.decodeQueueSize > MAX_QUEUED_FRAMES) needKeyframe = true;
          if (needKeyframe && !sample.keyframe) continue;
          needKeyframe = false;
          sent++;
          const data =
            mode === "avc"
              ? sample.data.slice()
              : sampleToAnnexB(sample.data, sample.keyframe ? parameterSets : null);
          decoder.decode(
            new EncodedVideoChunk({
              type: sample.keyframe ? "key" : "delta",
              timestamp: Math.round((sample.time * 1_000_000) / timescale),
              duration: Math.round((sample.duration * 1_000_000) / timescale),
              data,
            }),
          );
        }
      },
      close() {
        clearInterval(watchdog);
        if (decoder && decoder.state !== "closed") decoder.close();
      },
    };
  }

  /** Picks how this device can play `codec`; null when it can't. */
  function createSink(codec: string, failed: () => void): Sink | null {
    const type = `video/mp4; codecs="${codec}"`;
    const Source: typeof MediaSource | undefined =
      window.MediaSource ?? (window as { ManagedMediaSource?: typeof MediaSource }).ManagedMediaSource;
    if (Source?.isTypeSupported(type)) {
      painted = false;
      return mediaSourceSink(Source, type);
    }
    if (typeof VideoDecoder !== "undefined" && typeof EncodedVideoChunk !== "undefined") {
      painted = true;
      return decoderSink(codec, failed);
    }
    return null;
  }

  /** The player for the current connection; at most one at a time. */
  let sink: Sink | null = null;
  function stopSink() {
    try {
      sink?.close();
    } catch {
      // already closed by its own error
    }
    sink = null;
  }

  function connect() {
    stopSink();
    const ws = new WebSocket(agent.socketUrl("/api/stream/ws"));
    socket = ws;
    ws.binaryType = "arraybuffer";
    let gone = false;

    // The connection is over, however that was noticed: WebKit sometimes reports an error and
    // never follows it with a close, which used to leave the player waiting forever.
    const lost = () => {
      if (gone || socket !== ws) return;
      gone = true;
      socket = null;
      ws.onclose = ws.onerror = ws.onmessage = null;
      try {
        ws.close();
      } catch {
        // already closing
      }
      stopSink();
      if (closed) return;
      // Each form has failed twice without a single frame: retrying won't help.
      if (failedStarts >= MODES.length * 2) {
        status = "This device couldn't decode the mirroring stream";
        closed = true;
        return;
      }
      status = "Reconnecting…";
      clearTimeout(retry);
      retry = setTimeout(connect, 2000);
    };

    ws.onerror = ws.onclose = () => lost();
    ws.onmessage = event => {
      if (typeof event.data !== "string") {
        try {
          sink?.push(event.data);
        } catch {
          lost(); // reconnecting starts over with a keyframe
        }
        return;
      }
      const { codec } = JSON.parse(event.data);
      stopSink();
      sink = createSink(codec, () => lost());
      if (!sink) {
        status = isIOS() ? "Mirroring needs iOS 16.4 or newer" : `This device can't play ${codec}`;
        closed = true;
        lost();
        return;
      }
      status = "";
    };
  }

  // Catch up by playing faster; seeking restarts decoding at the last keyframe.
  function keepLive(buffer: SourceBuffer) {
    if (buffer.updating || !buffer.buffered.length) return;
    const start = buffer.buffered.start(0);
    const end = buffer.buffered.end(buffer.buffered.length - 1);
    const behind = end - video.currentTime;
    if (video.currentTime < start || behind > 2) video.currentTime = Math.max(start, end - 0.2);
    video.playbackRate = behind > 0.3 ? 1.1 : 1.0;
    if (video.paused) video.play().catch(() => {});
    if (video.currentTime - start > 10) buffer.remove(start, video.currentTime - 5);
  }

  // In the background the socket dies or, worse, keeps the Frame capturing for nobody:
  // stop it, and start fresh (new keyframe, no stale buffer) when the app comes back.
  function onVisibilityChange() {
    if (closed) return;
    clearTimeout(retry);
    if (socket) socket.onclose = socket.onerror = socket.onmessage = null;
    socket?.close();
    socket = null;
    stopSink();
    if (document.visibilityState === "visible") {
      status = "Connecting…";
      connect();
    }
  }

  onMount(connect);
  onDestroy(() => {
    if (fullscreen) applyFullscreen(false);
    closed = true;
    clearTimeout(retry);
    if (socket) socket.onclose = socket.onerror = socket.onmessage = null;
    socket?.close();
    stopSink();
    if (objectUrl) URL.revokeObjectURL(objectUrl);
  });
</script>

<svelte:document onfullscreenchange={onFullscreenChange} onvisibilitychange={onVisibilityChange} />

<div class="player" class:fullscreen>
  <video bind:this={video} autoplay muted playsinline hidden={painted}></video>
  <canvas bind:this={canvas} hidden={!painted}></canvas>
  {#if status}<div class="overlay">{status}</div>{/if}
  {#if fullscreen}
    <button class="control exit" onclick={() => history.back()} aria-label="Exit fullscreen">
      <Icon name="back" size={22} />
    </button>
  {:else}
    <button class="control enter" onclick={enterFullscreen} aria-label="Fullscreen">
      <svg viewBox="0 0 36 36" width="22" height="22" fill="currentColor" aria-hidden="true">
        <path d="M4 4h11v4H8v7H4zM21 4h11v11h-4V8h-7zM4 21h4v7h7v4H4zM28 21h4v11H21v-4h7z" />
      </svg>
    </button>
  {/if}
</div>

<Section title="Mirroring">
  <Row label="Resolution" value={stats ? `${stats.width}×${stats.height}` : null} />
  <Row label="Frame rate" value={stats ? `${stats.fps.toFixed(0)} fps (headset ${stats.source_fps.toFixed(0)})` : null} />
  <Row label="Bitrate" value={stats ? `${(stats.kbit_per_sec / 1000).toFixed(1)} Mbit/s` : null} />
  <Row label="Viewers" value={stats?.viewers} />
</Section>
<p class="hint muted">Mirroring only runs while someone watches. A sleeping headset shows black frames.</p>

<style>
  .player {
    position: relative;
    background: #000;
    aspect-ratio: 16 / 9;
  }
  video,
  canvas {
    width: 100%;
    height: 100%;
    display: block;
    object-fit: contain;
  }
  [hidden] {
    display: none;
  }
  .player.fullscreen {
    position: fixed;
    inset: 0;
    z-index: 10;
    aspect-ratio: auto;
  }
  .control {
    position: absolute;
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
    border: 0;
    border-radius: 2px;
    background: rgb(0 0 0 / 0.5);
    color: #fff;
  }
  .enter {
    right: 8px;
    bottom: 8px;
  }
  .exit {
    left: 12px;
    top: 12px;
  }
  .overlay {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    color: var(--muted);
  }
  .hint {
    padding: 12px var(--gutter);
    font-size: 13px;
  }
</style>
