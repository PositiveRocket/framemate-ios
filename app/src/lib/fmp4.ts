// Just enough fragmented-MP4 reading to feed the agent's mirroring stream to WebCodecs.
//
// The stream is made for Media Source Extensions (see crates/agent/src/fmp4.rs): an init segment
// (ftyp+moov) and then one moof+mdat per frame. iPhones have no MSE before iOS 17.1, so there the
// player decodes the H.264 samples itself with `VideoDecoder`, which needs two things out of the
// container: the decoder configuration (the `avcC` box) and each frame's bytes, time and
// keyframe flag.

/** A box's body (after the 8-byte size+type header), as a view into the same buffer. */
function child(bytes: Uint8Array, type: string, skip = 0): Uint8Array | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = skip;
  while (at + 8 <= bytes.length) {
    let size = view.getUint32(at);
    const name = String.fromCharCode(bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]);
    if (size === 0) size = bytes.length - at; // "to the end"
    if (size < 8 || at + size > bytes.length) return null; // 64-bit sizes don't occur here
    if (name === type) return bytes.subarray(at + 8, at + size);
    at += size;
  }
  return null;
}

/** Follows a path of nested boxes. `skips` gives the bytes of fields before a box's children. */
function descend(bytes: Uint8Array, path: string[], skips: Record<string, number> = {}): Uint8Array | null {
  let body: Uint8Array | null = bytes;
  let skip = 0;
  for (const type of path) {
    body = child(body, type, skip);
    if (!body) return null;
    skip = skips[type] ?? 0;
  }
  return body;
}

export interface StreamConfig {
  /** The AVCDecoderConfigurationRecord, i.e. `VideoDecoderConfig.description`. */
  description: Uint8Array;
  /** Units per second of the sample times. */
  timescale: number;
}

/** Reads the init segment (ftyp+moov). Null when it isn't one. */
export function parseInit(bytes: Uint8Array): StreamConfig | null {
  const media = descend(bytes, ["moov", "trak", "mdia"]);
  if (!media) return null;
  // stsd: version/flags + entry count before the sample entry; avc1: 78 bytes of fields.
  const description = descend(media, ["minf", "stbl", "stsd", "avc1", "avcC"], { stsd: 8, avc1: 78 });
  const mdhd = child(media, "mdhd");
  if (!description || !mdhd || mdhd.length < 24) return null;
  const view = new DataView(mdhd.buffer, mdhd.byteOffset, mdhd.byteLength);
  // After version/flags: creation and modification time, 4 bytes each (version 0) or 8 (version 1).
  const timescale = view.getUint32(mdhd[0] === 1 ? 20 : 12);
  return { description, timescale: timescale || 90_000 };
}

export interface Sample {
  data: Uint8Array;
  /** Decode time and duration, in the stream's timescale. */
  time: number;
  duration: number;
  keyframe: boolean;
}

/** Whether a length-prefixed H.264 sample contains an IDR slice (NAL type 5). */
function hasIdr(sample: Uint8Array): boolean {
  const view = new DataView(sample.buffer, sample.byteOffset, sample.byteLength);
  let at = 0;
  while (at + 5 <= sample.length) {
    if ((sample[at + 4] & 0x1f) === 5) return true;
    at += 4 + view.getUint32(at);
  }
  return false;
}

/** Reads one media segment (moof+mdat). The agent sends one sample per segment; all are returned. */
export function parseSegment(bytes: Uint8Array): Sample[] {
  const moof = child(bytes, "moof");
  const mdat = child(bytes, "mdat");
  const traf = moof && child(moof, "traf");
  const tfdt = traf && child(traf, "tfdt");
  const trun = traf && child(traf, "trun");
  if (!moof || !mdat || !tfdt || !trun || trun.length < 8) return [];
  // tfhd has default-base-is-moof: data offsets count from the start of the moof box.
  const moofStart = moof.byteOffset - bytes.byteOffset - 8;

  const times = new DataView(tfdt.buffer, tfdt.byteOffset, tfdt.byteLength);
  let time = tfdt[0] === 1 ? Number(times.getBigUint64(4)) : times.getUint32(4);

  const view = new DataView(trun.buffer, trun.byteOffset, trun.byteLength);
  const flags = view.getUint32(0) & 0xffffff;
  const count = view.getUint32(4);
  let at = 8;
  let offset = mdat.byteOffset - bytes.byteOffset; // without a data offset: the start of mdat
  if (flags & 0x1) {
    offset = moofStart + view.getInt32(at);
    at += 4;
  }
  let firstFlags: number | null = null;
  if (flags & 0x4) {
    firstFlags = view.getUint32(at);
    at += 4;
  }

  const samples: Sample[] = [];
  for (let n = 0; n < count; n++) {
    const fields = ((flags & 0x100) ? 4 : 0) + ((flags & 0x200) ? 4 : 0) + ((flags & 0x400) ? 4 : 0) + ((flags & 0x800) ? 4 : 0);
    if (at + fields > trun.length) break;
    let duration = 0;
    let size = bytes.length - offset; // no size given: the rest (one sample per segment)
    let sampleFlags = n === 0 ? firstFlags : null;
    if (flags & 0x100) (duration = view.getUint32(at)), (at += 4);
    if (flags & 0x200) (size = view.getUint32(at)), (at += 4);
    if (flags & 0x400) (sampleFlags = view.getUint32(at)), (at += 4);
    if (flags & 0x800) at += 4; // composition offset: the stream has no B-frames
    if (size <= 0 || offset + size > bytes.length) break;
    const data = bytes.subarray(offset, offset + size);
    // sample_is_non_sync_sample is bit 16; without flags, look at the NAL units instead.
    const keyframe = sampleFlags === null ? hasIdr(data) : (sampleFlags & 0x10000) === 0;
    samples.push({ data, time, duration, keyframe });
    offset += size;
    time += duration;
  }
  return samples;
}

// --- Annex B, the other way to feed H.264 to WebCodecs ---
// With no `description`, VideoDecoder takes the raw stream: NAL units behind 00 00 00 01 start
// codes, with SPS/PPS in front of each keyframe. Some decoders (Safari 16.4's among them) fail on
// one of the two forms and not the other, so the player can switch.

const START_CODE = [0, 0, 0, 1];

/** SPS and PPS out of an AVCDecoderConfigurationRecord, as Annex B. Null when malformed. */
export function parameterSetsAnnexB(description: Uint8Array): Uint8Array | null {
  // version, profile, compatibility, level, length size; then SPS count (low 5 bits) + SPSs,
  // then PPS count + PPSs, each set behind a 2-byte length.
  const out: number[] = [];
  let at = 5;
  const sets = (count: number) => {
    for (let i = 0; i < count; i++) {
      if (at + 2 > description.length) return false;
      const len = (description[at] << 8) | description[at + 1];
      at += 2;
      if (at + len > description.length) return false;
      out.push(...START_CODE, ...description.subarray(at, at + len));
      at += len;
    }
    return true;
  };
  if (at >= description.length || !sets(description[at++] & 0x1f)) return null;
  if (at >= description.length || !sets(description[at++])) return null;
  return out.length ? new Uint8Array(out) : null;
}

/** A length-prefixed sample as Annex B, with `prefix` (the parameter sets) in front. */
export function sampleToAnnexB(sample: Uint8Array, prefix?: Uint8Array | null): Uint8Array {
  const parts: Uint8Array[] = prefix ? [prefix] : [];
  const view = new DataView(sample.buffer, sample.byteOffset, sample.byteLength);
  let at = 0;
  while (at + 4 <= sample.length) {
    const len = view.getUint32(at);
    if (at + 4 + len > sample.length) break;
    parts.push(new Uint8Array(START_CODE), sample.subarray(at + 4, at + 4 + len));
    at += 4 + len;
  }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** The NAL unit types in a length-prefixed sample, for diagnostics. */
export function nalTypes(sample: Uint8Array): number[] {
  const view = new DataView(sample.buffer, sample.byteOffset, sample.byteLength);
  const types: number[] = [];
  let at = 0;
  while (at + 5 <= sample.length && types.length < 16) {
    types.push(sample[at + 4] & 0x1f);
    at += 4 + view.getUint32(at);
  }
  return types;
}
