// node audio.mjs -> music.wav, scored to timeline.json (written by render.mjs).
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const T = JSON.parse(readFileSync(path.join(here, 'timeline.json')));
const SR = 48000, N = Math.ceil((T.end + 0.05) * SR);
const dry = [new Float32Array(N), new Float32Array(N)];
const send = [new Float32Array(N), new Float32Array(N)];

const TAU = Math.PI * 2;
const hz = m => 440 * Math.pow(2, (m - 69) / 12);
const note = s => {                       // 'F3', 'Bb2', 'C#4'
  const [, l, acc, o] = s.match(/^([A-G])(b|#)?(-?\d)$/);
  return 12 * (+o + 1) + { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[l] + (acc === 'b' ? -1 : acc === '#' ? 1 : 0);
};
let seed = 7;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const noise = () => rand() * 2 - 1;

// Adds a voice: fn(t) -> sample, over `dur` seconds from `at`, panned -1..1, with a reverb send.
function add(at, dur, fn, { gain = 1, pan = 0, wet = 0.2 } = {}) {
  const l = Math.cos((pan + 1) * Math.PI / 4), r = Math.sin((pan + 1) * Math.PI / 4);
  const s0 = Math.round(at * SR);
  for (let i = 0; i < dur * SR && s0 + i < N; i++) {
    if (s0 + i < 0) continue;
    const v = fn(i / SR) * gain;
    dry[0][s0 + i] += v * l; dry[1][s0 + i] += v * r;
    send[0][s0 + i] += v * l * wet; send[1][s0 + i] += v * r * wet;
  }
}

// RBJ band-pass, retuned as it goes so a whoosh can sweep.
function bandpass(q) {
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x, f) => {
    const w = TAU * f / SR, a = Math.sin(w) / (2 * q), c = Math.cos(w), a0 = 1 + a;
    const y = (a * x - a * x2 - (-2 * c) * y1 - (1 - a) * y2) / a0;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

// ---------------------------------------------------------------- instruments
const release = (t, dur, r = 0.08) => t < dur ? 1 : Math.max(0, 1 - (t - dur) / r);

function keys(at, notes, { gain = 0.08, dur = 2.4, pan = 0 } = {}) {   // soft FM electric piano
  notes.forEach((n, k) => {
    const f = hz(note(n)), p = pan + (k - notes.length / 2) * 0.08;
    add(at + k * 0.012, dur + 0.8, t => {
      const env = (1 - Math.exp(-t * 90)) * Math.exp(-t * 0.9) * release(t, dur, 0.7);
      const idx = 0.9 * Math.exp(-t * 6) + 0.15;
      return env * Math.sin(TAU * f * t + idx * Math.sin(TAU * f * t)) * (1 + 0.05 * Math.sin(TAU * 4.2 * t));
    }, { gain, pan: p, wet: 0.4 });
  });
}
// Mostly second harmonic, so the line reads on small speakers without piling up sub.
function bass(at, n, dur, gain = 0.14) {
  const f = hz(note(n));
  add(at, dur + 0.15, t => (1 - Math.exp(-t * 200)) * Math.exp(-t * 1.6) * release(t, dur, 0.1)
    * (0.55 * Math.sin(TAU * f * t) + 0.6 * Math.sin(TAU * 2 * f * t) + 0.12 * Math.sin(TAU * 3 * f * t)), { gain, wet: 0.06 });
}
function kick(at, gain = 0.2) {                  // a soft felt thump, not a club kick
  let ph = 0;
  add(at, 0.3, t => { ph += TAU * (62 + 60 * Math.exp(-t * 35)) / SR; return Math.sin(ph) * Math.exp(-t * 14); },
    { gain, wet: 0.04 });
}
function rim(at, gain = 0.05) {
  const bp = bandpass(1.8);
  add(at, 0.15, t => (bp(noise(), 2100) * 2.5 + 0.4 * Math.sin(TAU * 520 * t)) * Math.exp(-t * 45),
    { gain, pan: -0.2, wet: 0.35 });
}
function shaker(at, gain = 0.02) {
  const bp = bandpass(0.9);
  add(at, 0.1, t => bp(noise(), 7500) * 2 * (1 - Math.exp(-t * 250)) * Math.exp(-t * 50),
    { gain, pan: 0.3, wet: 0.12 });
}
function click(at, gain = 0.05, pan = 0) {       // a keycap: a short top click over a low thock
  const bp = bandpass(2.2), g = gain * (0.85 + 0.3 * rand()), p = pan + (rand() - 0.5) * 0.2;
  add(at, 0.07, t => (bp(noise(), 2800 + 600 * rand()) * 2.2 * Math.exp(-t * 260)
    + 0.5 * Math.sin(TAU * 190 * t) * Math.exp(-t * 90)), { gain: g, pan: p, wet: 0.2 });
}
function tick(at, gain = 0.2) {                  // the mark switching: clean, tuned C6 over F5
  const bp = bandpass(3);
  add(at, 1.2, t => (1 - Math.exp(-t * 3000)) * (Math.sin(TAU * hz(84) * t) * Math.exp(-t * 9)
    + 0.45 * Math.sin(TAU * hz(77) * t) * Math.exp(-t * 6)
    + 0.08 * Math.sin(TAU * hz(84) * 2.76 * t) * Math.exp(-t * 30))
    + bp(noise(), 5000) * Math.exp(-t * 900) * 0.6, { gain, pan: 0.15, wet: 0.3 });
}
function plip(at, n, { gain = 0.05, bend = 0, pan = 0.3 } = {}) {   // marimba
  const f = hz(note(n));
  let ph1 = 0, ph2 = 0;
  add(at, 1.2, t => {
    const k = Math.pow(2, bend * Math.min(1, t / 0.25) / 12);
    ph1 += TAU * f * k / SR; ph2 += TAU * f * k * 3.93 / SR;
    return (1 - Math.exp(-t * 900)) * (Math.sin(ph1) * Math.exp(-t * 6) + 0.18 * Math.sin(ph2) * Math.exp(-t * 24));
  }, { gain, pan, wet: 0.4 });
}
function air(at, dur, dir, gain = 0.04) {        // band-passed breath that travels with the pan
  for (let c = 0; c < 2; c++) {
    const bpc = bandpass(1.1);
    add(at, dur, t => {
      const p = t / dur, env = Math.pow(Math.sin(Math.PI * p), 2);
      const pan = dir * (2 * p - 1), side = c ? (1 + pan) / 2 : (1 - pan) / 2;
      return bpc(noise(), 500 * Math.pow(6, Math.sin(Math.PI * p))) * env * side * 1.6;
    }, { gain, pan: c ? 1 : -1, wet: 0.35 });
  }
}

// ---------------------------------------------------------------- score
const B = T.beat, beat = k => k * B;
const frame = s => Math.ceil(s * T.fps - 1e-6) / T.fps;   // the first frame that shows an event at s

// Chords change on beats; each rings until the next.
const chords = [
  [0, ['D3', 'F3', 'A3', 'C4', 'E4'], 'D2', 0.06],
  [4, ['Bb2', 'D3', 'F3', 'A3', 'C4'], 'Bb2', 0.06],
  [7, ['F3', 'A3', 'C4', 'E4', 'G4'], 'F2', 0.075],
  [11, ['D3', 'F3', 'A3', 'C4', 'E4'], 'D2', 0.07],
  [13, ['Bb2', 'D3', 'F3', 'A3', 'C4'], 'Bb2', 0.07],
  [15, ['C3', 'F3', 'G3', 'Bb3', 'D4'], 'C2', 0.065],
  [17, ['F3', 'A3', 'C4', 'E4', 'A4'], 'F2', 0.085],
  [21, ['D3', 'F3', 'A3', 'C4', 'E4'], 'D2', 0.075],
  [23, ['Bb2', 'D3', 'F3', 'A3', 'C4', 'F4'], 'Bb2', 0.08],
  [25, ['C3', 'E3', 'G3', 'Bb3', 'D4'], 'C2', 0.075],
  [27, ['F3', 'A3', 'C4', 'E4', 'G4', 'C5'], 'F2', 0.085],
];
chords.forEach(([b, notes, root, g], k) => {
  const at = beat(b), next = chords[k + 1] ? beat(chords[k + 1][0]) : T.end, len = next - at;
  keys(at, notes, { gain: g, dur: len });
  if (b >= 7) {
    bass(at, root, Math.min(len, 1.5 * B) - 0.05, b >= 17 ? 0.15 : 0.11);
    if (len > 2.5 * B) bass(at + 2.5 * B, root, B * 0.8, 0.09);
  } else bass(at, root, len * 0.8, 0.06);
});
bass(beat(27), 'F2', T.end - beat(27), 0.12);

// The pulse enters with the reveal, breathes out for the pan, and fills out from the switch.
for (let k = 7; k < 27; k++) {
  const at = beat(k), full = k >= 17;
  if (k === 16) continue;
  if ((k - 7) % 2 === 0) kick(at, full ? 0.2 : 0.15);
  if (full && (k - 7) % 2 === 1) rim(at);
  shaker(at + B / 2 + 0.02, full ? 0.028 : 0.02);
  if (full) shaker(at, 0.014);
}
kick(beat(27), 0.2);

// Hook: the keys, and a soft bump on the typo.
T.hook.keys.forEach(k => click(frame(k.at), 0.075));
plip(frame(T.hook.flag), 'D3', { gain: 0.16, bend: -1, pan: 0 });
bass(frame(T.hook.flag), 'D2', 0.4, 0.1);

// The popover's rows land in key.
T.rows.forEach((r, i) => plip(frame(r), ['A5', 'C6', 'E6'][i], { gain: 0.045 }));

// In use: the keys, the pan, and the switch on the keydown frame.
T.legA.forEach(k => click(frame(k.at), 0.05, -0.2));
air(T.handAt, 0.5, -1, 0.035);
T.legB.forEach(k => click(frame(k.at), 0.05, 0.2));
tick(frame(T.switchAt), 0.2);

// g's swoosh wipes: a breath that travels across the stereo field with each band.
T.cuts.forEach((c, i) => air(c - (T.wipe + 0.2) / 2, T.wipe + 0.2, i % 2 ? -1 : 1, 0.055));

// ---------------------------------------------------------------- reverb (Freeverb, small)
function reverb(input, spread) {
  const out = new Float32Array(N);
  const combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617].map(d => ({
    buf: new Float32Array(Math.round((d + spread) * SR / 44100)), i: 0, store: 0 }));
  const aps = [556, 441, 341, 225].map(d => ({ buf: new Float32Array(Math.round((d + spread) * SR / 44100)), i: 0 }));
  for (let n = 0; n < N; n++) {
    const x = input[n] * 0.015;
    let y = 0;
    for (const c of combs) {
      const o = c.buf[c.i];
      c.store = o * 0.7 + c.store * 0.3;          // damping
      c.buf[c.i] = x + c.store * 0.84;            // room size
      c.i = (c.i + 1) % c.buf.length;
      y += o;
    }
    for (const a of aps) {
      const b = a.buf[a.i];
      a.buf[a.i] = y + b * 0.5;
      a.i = (a.i + 1) % a.buf.length;
      y = b - y;
    }
    out[n] = y;
  }
  return out;
}
const wet = [reverb(send[0], 0), reverb(send[1], 23)];

// ---------------------------------------------------------------- mix + write
const pcm = Buffer.alloc(44 + N * 4);
pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + N * 4, 4); pcm.write('WAVEfmt ', 8);
pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(2, 22);
pcm.writeUInt32LE(SR, 24); pcm.writeUInt32LE(SR * 4, 28); pcm.writeUInt16LE(4, 32); pcm.writeUInt16LE(16, 34);
pcm.write('data', 36); pcm.writeUInt32LE(N * 4, 40);
// Master high-pass: a 2nd-order RBJ at 45 Hz keeps the sub in check.
const hpf = () => {
  const w = TAU * 45 / SR, a = Math.sin(w) / (2 * 0.707), c = Math.cos(w), a0 = 1 + a;
  const b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, a1 = -2 * c / a0, a2 = (1 - a) / a0;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return x => { const y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2; x2 = x1; x1 = x; y2 = y1; y1 = y; return y; };
};
const hp = [hpf(), hpf()];
const fadeOut = Math.round(0.8 * SR);
for (let n = 0; n < N; n++) for (let c = 0; c < 2; c++) {
  let v = hp[c](dry[c][n] + wet[c][n] * 3.2);
  v *= Math.min(1, (N - n) / fadeOut);
  v = Math.tanh(v * 1.1);
  pcm.writeInt16LE(Math.round(v * 32000), 44 + (n * 2 + c) * 2);
}
writeFileSync(path.join(here, 'music.wav'), pcm);
console.log('music.wav', (N / SR).toFixed(2), 's');
