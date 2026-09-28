// The hero's loop as a pure function of time. One clock and no timers, so any moment
// can be asked for directly: the page plays it, the reduced-motion still is one frame of
// it, make-demo.mjs captures it for the README, and hero-check.mjs tests it without a
// browser.
//
// The story, on the video's beat: "Hello! " on the Keychron K2 in the middle,
// then the row slides to put the built-in keyboard in the centre for "Grüße! ", then on
// to the MX Keys for "안녕!", and back. Every switch lands on the frame its key goes
// down, and what that key prints is already in the new layout — that is what "Before
// key press" buys, and the page never shows the other thing.

const B = 0.625;                  // one beat at the video's 96 BPM
const S = B / 4;                  // typing runs in sixteenths

export const LOOP = 16 * B;       // 10 s, four bars
export const STILL = 13 * B;      // all three words typed and everything settled: where
                                  // the page opens, and the one frame reduced motion shows

const SWAP = 0.3;                 // MenuBarMark's swap, as AppState.animateMark runs it
const HOT = 0.4;                  // coral fading back to ink once the swap is done
export const RING = 0.9;          // the rings leaving the key and the mark
const LINE = 0.45;                // the dotted line joining them
const TAP = 0.11;                 // how long an ordinary key stays down
const LIFT = 0.1;                 // and how long it takes to come back up
const FLASH = [0.15, 0.6];        // ü and ß: hold coral, then fade to ink
const LEAD = 0.12;                // how long before the key the hands get there
const FADE = [15 * B, 0.3];       // the field empties at 9.375 s
const BACK = 9.7;                 // then the hands return to the K2

// Left to right as the desk lays them out, which is also the popover's row order: the
// index is the rail's row.
export const BOARDS = [
  { name: 'Apple Internal', source: 'German', code: 'DE' },
  { name: 'Keychron K2', source: 'U.S.', code: 'EN' },
  { name: 'MX Keys', source: '2-Set Korean', code: 'KO' },
];

// A plain layout prints one character per key; the leg reads its first i + 1.
const plain = text => [...text].map((_, i, all) => [all.slice(0, i + 1).join(''), 0]);

// One leg per keyboard: the sixteenths its keys land on, the keys held, and what the leg
// reads after each, with how many of its last characters the input method still holds.
// The first key of a leg is the switch; the German and Korean words rest a sixteenth
// after it, as the video's German one does.
//
// 2-Set Korean puts consonants and vowels on separate keys and builds syllables out of
// them, so 안녕 is six keys, not two: d k s make ㅇ 아 안, and
// s u d make 안ㄴ 안녀 안녕 — the fourth starts a new syllable, since ㄴㄴ is no final.
// Only the syllable in hand is composing.
const LEGS = [
  { board: 1, at: [4, 5, 6, 7, 8, 9, 10],
    keys: [['⇧', 'H'], ['E'], ['L'], ['L'], ['O'], ['⇧', '1'], ['space']], reads: plain('Hello! ') },
  { board: 0, at: [20, 22, 23, 24, 25, 26, 27],
    keys: [['⇧', 'G'], ['R'], ['Ü'], ['ß'], ['E'], ['⇧', '1'], ['space']], reads: plain('Grüße! ') },
  { board: 2, at: [36, 38, 39, 40, 41, 42, 43],
    keys: [['D'], ['K'], ['S'], ['S'], ['U'], ['D'], ['⇧', '1']],
    reads: [['ㅇ', 1], ['아', 1], ['안', 1], ['안ㄴ', 1], ['안녀', 1], ['안녕', 1], ['안녕!', 0]] },
];

// Every keystroke: the board, when, the keys held, and the whole field after it. The
// board typed on before a leg is the previous leg's; for the first that is the last
// one's, since the loop comes round from the MX Keys.
export const STROKES = LEGS.flatMap((leg, l) => {
  const before = LEGS.slice(0, l).map(g => g.reads.at(-1)[0]).join('');
  const from = LEGS.at(l - 1).board;
  return leg.at.map((n, i) => {
    const [reads, composing] = leg.reads[i];
    const text = before + reads;
    return {
      board: leg.board, at: n * S, keys: leg.keys[i], text, composing, from, switches: i === 0,
      // What a U.S. layout cannot type flashes as it comes out right. A syllable the
      // input method is still building has its underline instead.
      flash: !composing && /[^\x00-\x7f]/.test(text.at(-1)),
    };
  });
});

export const SWITCHES = STROKES.filter(s => s.switches);

// The hands between keyboards, and the row sliding to centre the one they go to. Two
// boards over takes a little longer than one.
const MOVES = [
  { to: 0, time: 0.5 },
  { to: 2, time: 0.75 },
  { to: 1, time: 0.5, at: BACK },
].map((m, i, all) => ({ ...m, at: m.at ?? SWITCHES[i + 1].at - LEAD - m.time, from: all.at(i - 1).to }));

const clamp = x => Math.min(1, Math.max(0, x));
const smooth = x => (x = clamp(x), x * x * (3 - 2 * x));
const ease = x => (x = clamp(x), x < 0.5 ? 4 * x ** 3 : 1 - (-2 * x + 2) ** 3 / 2);

// The latest item at or before t, and when it happened. With none yet in this loop it is
// the last one of the previous loop, a LOOP earlier — so the opening frames carry on
// from the closing ones.
function latest(items, t) {
  const item = items.findLast(i => i.at <= t);
  return item ? [item, item.at] : [items.at(-1), items.at(-1).at - LOOP];
}

export function state(t) {
  t = ((t % LOOP) + LOOP) % LOOP;

  // The field: the last keystroke's text, until it fades out for the next round.
  const done = t < FADE[0] + FADE[1] ? STROKES.findLast(s => s.at <= t) : null;
  const chars = [...(done?.text ?? '')];
  const text = chars.map(ch => ({ ch, flash: 0 }));
  for (const s of STROKES) {
    if (s.flash && s.at <= t && done) text[[...s.text].length - 1].flash = 1 - smooth((t - s.at - FLASH[0]) / FLASH[1]);
  }
  const composing = done?.composing ?? 0;
  const fade = 1 - smooth((t - FADE[0]) / FADE[1]);
  const since = t - latest(STROKES, t)[1];
  const caret = since < 0.5 || Math.floor(since * 1.9) % 2 === 0;

  // The keys down right now, 1 while held and falling to 0 as they come back up. The
  // key that switches stays down for the length of the swap, so the two read as one
  // event, and prints coral.
  const keys = [];
  for (const s of STROKES) {
    const d = t - s.at, hold = s.switches ? SWAP : TAP;
    if (d < 0 || d >= hold + LIFT) continue;

    const down = d < hold ? 1 : 1 - (d - hold) / LIFT;
    for (const key of s.keys) keys.push({ board: s.board, key, down, hot: s.switches && key !== '⇧' });
  }

  // The mark and the rail are one event in the app, so they change on the same frame.
  const [sw, at] = latest(SWITCHES, t), d = t - at;
  const mark = {
    from: BOARDS[sw.from].code,
    to: BOARDS[sw.board].code,
    progress: smooth(d / SWAP),
    hot: 1 - smooth((d - SWAP) / HOT),
  };
  const rail = sw.board;
  const ring = d < RING ? { board: sw.board, key: sw.keys.at(-1), grow: d / RING, line: d / LINE } : null;

  // Where the row sits, in boards: 1 centres the K2. The veils trade between the board
  // the hands leave and the one they go to; one they pass over stays veiled.
  const [move, moved] = latest(MOVES, t);
  const e = ease((t - moved) / move.time);
  const pan = move.from + (move.to - move.from) * e;
  const idle = BOARDS.map((_, i) => i === move.to ? 1 - e : i === move.from ? e : 1);

  return { text, composing, fade, caret, keys, mark, rail, ring, pan, idle };
}
