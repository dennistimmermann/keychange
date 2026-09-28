// Self-check for docs/js/story.js, the landing page's hero loop: node hero-check.mjs
//
// The page can only show what state(t) says, so the promises the hero makes are checked
// here, on the timeline, rather than by eye on a moving page.

import assert from 'node:assert/strict';
import { LOOP, STILL, BOARDS, STROKES, SWITCHES, state } from './docs/js/story.js';

const FRAME = 1 / 60;
const read = s => s.fade > 0 ? s.text.map(c => c.ch).join('') : '';
// What the page draws, to a millionth: the row is mid-slide at the seam.
const shown = s => JSON.parse(JSON.stringify({
  text: read(s), composing: s.composing, caret: s.caret, keys: s.keys, mark: s.mark,
  rail: s.rail, ring: s.ring, pan: s.pan, idle: s.idle,
}, (_, v) => typeof v === 'number' ? +v.toFixed(6) : v));

// The seam: the last moment of the loop looks like its first, and LOOP is 0 again.
assert.deepEqual(shown(state(LOOP - 1e-9)), shown(state(0)), 'the loop seams');
assert.deepEqual(state(LOOP), state(0), 'LOOP wraps to 0');
assert.equal(LOOP % (4 * 0.625), 0, 'the loop is whole bars');

// Each switch lands on the frame its key goes down: the key is down and coral, the mark
// is on its way to the new code and fully coral, the rail has moved, the rings start and
// the character is printed in the new layout. One frame earlier none of it has happened,
// and nothing of the new word is on the field.
for (const sw of SWITCHES) {
  const now = state(sw.at), before = state(sw.at - FRAME);
  const board = BOARDS[sw.board], key = sw.keys.at(-1);

  assert.ok(now.keys.some(k => k.board === sw.board && k.key === key && k.down === 1 && k.hot), `${key} down, coral`);
  assert.equal(now.mark.to, board.code, `mark heads for ${board.code}`);
  assert.equal(now.mark.progress, 0, 'swap starts on the keydown frame');
  assert.equal(now.mark.hot, 1, 'mark fully coral');
  assert.equal(now.rail, sw.board, 'rail moved');
  assert.ok(now.ring && now.ring.grow === 0 && now.ring.key === key, 'rings start');
  assert.equal(read(now), sw.text, `${sw.text.at(-1)} printed`);

  assert.notEqual(before.mark.to, board.code, 'nothing switched a frame early');
  assert.notEqual(before.rail, sw.board, 'rail not moved a frame early');
  assert.ok(!before.keys.some(k => k.hot), 'no coral key a frame early');
  assert.equal(before.mark.hot, 0, 'no coral mark a frame early');
  assert.equal(before.ring, null, 'no rings a frame early');
  assert.equal(read(before), sw.text.slice(0, -1), 'the first character not shown before its switch');

  // The hands are already there, and still, a tenth of a second before.
  for (const dt of [0.1, 0.05, 0]) {
    const s = state(sw.at - dt);
    assert.equal(s.pan, sw.board, `row centred on ${board.name} ${dt}s before`);
    assert.equal(s.idle[sw.board], 0, `${board.name} unveiled ${dt}s before`);
  }
}

// Every keystroke lands on the keyboard the hands are on, centred and unveiled, and only
// ever on that one.
for (const s of STROKES) {
  const now = state(s.at);
  assert.equal(now.pan, s.board, `${s.text.at(-1)} typed on ${BOARDS[s.board].name}`);
  assert.deepEqual(now.idle, BOARDS.map((_, i) => i === s.board ? 0 : 1), 'the others veiled');
}

// Each leg is the payoff for the one before: ü and ß only come out right on the German
// board, 안녕 only on the Korean one.
assert.ok(STROKES.filter(s => s.flash).every(s => s.board === 0), 'ü and ß typed on the German board');
assert.deepEqual(STROKES.filter(s => s.flash).map(s => s.text.at(-1)), ['ü', 'ß'], 'ü and ß flash');

// Korean composes: the field steps through the input method's states, only the syllable
// in hand is underlined, and the leg ends committed.
const korean = STROKES.filter(s => s.board === 2).map(s => {
  const now = state(s.at), text = read(now);
  return [text.slice('Hello! Grüße! '.length), now.composing];
});
assert.deepEqual(korean, [['ㅇ', 1], ['아', 1], ['안', 1], ['안ㄴ', 1], ['안녀', 1], ['안녕', 1], ['안녕!', 0]],
  'ㅇ 아 안 안ㄴ 안녀 안녕 안녕!');

// The still is the rest: all three words, settled, nothing coral, nothing pressed or
// composing, and the caret on.
const still = state(STILL);
assert.equal(read(still), 'Hello! Grüße! 안녕!', 'the still shows all three words');
assert.equal(still.composing, 0, 'nothing composing');
assert.equal(still.mark.progress, 1, 'mark settled');
assert.equal(still.mark.hot, 0, 'mark ink');
assert.equal(still.mark.to, 'KO', 'mark on KO');
assert.equal(still.rail, 2, 'rail on MX Keys');
assert.equal(still.pan, 2, 'row centred on MX Keys');
assert.deepEqual(still.idle, [1, 1, 0], 'only MX Keys unveiled');
assert.equal(still.ring, null, 'no rings');
assert.equal(still.keys.length, 0, 'no keys down');
assert.ok(still.text.every(c => c.flash === 0), 'no coral text');
assert.equal(still.fade, 1, 'text fully shown');
assert.ok(still.caret, 'caret on');

console.log(`hero: loop seams at ${LOOP} s, ${SWITCHES.length} switches land on their keydown frame, `
  + 'Korean composes, the still is settled');
