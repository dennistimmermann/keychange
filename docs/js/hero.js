// The hero's demo: story.js played on the page. The menu bar card, the popover and the
// field are elements in index.html; this builds the three keyboards, then applies one
// state(t) per frame, writing only what changed. A settled frame costs nothing; only a
// keystroke lays out the page, and the rings their own small layer.

import { LOOP, STILL, state } from './story.js';
import { draw, SIZE } from './mark.js';
import { spread, out } from './ring.js';

// A plain 60% board, four rows of it: the desk dissolves it into dots below the third.
// The German keyboard is the U.S. one with other letters printed on it, which is the
// whole problem; the Korean one is the U.S. one with jamo printed beside the letters.
// [legend, width in keys]
const ROWS = {
  us: [
    ['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', ['⌫', 2]],
    [['⇥', 1.5], 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', ['\\', 1.5]],
    [['⇪', 1.75], 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'", ['↩', 2.25]],
    [['⇧', 2.25], 'Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', ['⇧', 2.75]],
  ],
  de: [
    ['^', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'ß', '´', ['⌫', 2]],
    [['⇥', 1.5], 'Q', 'W', 'E', 'R', 'T', 'Z', 'U', 'I', 'O', 'P', 'Ü', '+', ['↩', 1.5]],
    [['⇪', 1.75], 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'Ö', 'Ä', '#', ['', 1.25]],
    [['⇧', 1.25], '<', 'Y', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '-', ['⇧', 2.75]],
  ],
};
ROWS.ko = ROWS.us;
const SYMBOLS = '⇧⇥⇪⌫↩';

// 2-Set Korean's jamo by Latin key: d k s u are ㅇ ㅏ ㄴ ㅕ.
const JAMO = {
  Q: 'ㅂ', W: 'ㅈ', E: 'ㄷ', R: 'ㄱ', T: 'ㅅ', Y: 'ㅛ', U: 'ㅕ', I: 'ㅑ', O: 'ㅐ', P: 'ㅔ',
  A: 'ㅁ', S: 'ㄴ', D: 'ㅇ', F: 'ㄹ', G: 'ㅎ', H: 'ㅗ', J: 'ㅓ', K: 'ㅏ', L: 'ㅣ',
  Z: 'ㅋ', X: 'ㅌ', C: 'ㅊ', V: 'ㅍ', B: 'ㅠ', N: 'ㅜ', M: 'ㅡ',
};

const hero = document.querySelector('.hero');
const $ = selector => hero.querySelector(selector);
const mark = $('.mark'), typed = $('.typed'), caret = $('.caret'), rail = $('.rail');
const desk = $('.desk'), track = $('.track'), pause = $('.pause'), layer = $('.rings');
const [line, keyRing, markRing] = layer.children;
const boards = [...hero.querySelectorAll('.board')];
const caps = [...hero.querySelectorAll('.caps')];
const blobs = [...hero.querySelectorAll('.blob')];

// Drawn off the document: setting a font on a page canvas restyles the page first,
// every frame of a swap. Safari before 16.4 has no OffscreenCanvas and pays that.
const pen = (mark.transferControlToOffscreen?.() ?? mark).getContext('2d');
const css = getComputedStyle(document.documentElement);
const ink = css.getPropertyValue('--ink').trim(), coral = css.getPropertyValue('--accent').trim();

// Each board's keys by legend. The first of a legend wins, so ⇧ is the left shift.
const keys = caps.map(cap => {
  const found = {};
  ROWS[cap.dataset.layout].forEach((row, y) => {
    let x = 0;
    for (const k of row) {
      const [legend, w] = Array.isArray(k) ? k : [k, 1];
      const key = document.createElement('span');
      key.textContent = legend;
      if (cap.dataset.layout === 'ko' && JAMO[legend]) key.append(Object.assign(document.createElement('i'), { textContent: JAMO[legend] }));
      key.style.cssText = `--x: ${x}; --y: ${y}; --w: ${w}`;
      if (SYMBOLS.includes(legend)) key.className = 'sym';
      cap.append(key);
      found[legend] ??= key;
      x += w;
    }
  });
  return found;
});

// Writes a style property only when its value changes: most frames change nothing.
function put(el, name, value) {
  value = String(typeof value === 'number' ? +value.toFixed(3) : value);
  if (el.style.getPropertyValue(name) !== value) el.style.setProperty(name, value);
}

// ---------------------------------------------------------------- layout
// The row slides to bring story.js's `pan` board into place: 0 the first (left) board,
// 1 the second, 2 the third. The middle one always comes to the centre of the page. On a
// wide window the outer ones stop flush with the page's column, left and right, so the row
// moves no further than it has to; on a narrow one there is no room beside the middle, so
// they come to the centre too. Between the two widths they ease from one to the other.
// The boards are the same size, so their centres are evenly spaced.
// ?centred keeps every board in the middle at any width, for make-demo.mjs: the README's
// frame is narrower than the page's column.
const centred = new URLSearchParams(location.search).has('centred');
const WIDE = 1600, NARROW = 900;     // window widths: outer boards at the column's edges, centred
let first = 0, pitch = 0, edge = 0, far = 0, mid = 0, half = 0, pull = 0, scale = 0, spots = new Map(), placed = null;

function measure() {
  const [a, b] = boards.map(board => board.parentElement.offsetLeft + board.parentElement.offsetWidth / 2);
  first = a;
  pitch = b - a;

  // The column's inner edges and the page's middle, in the desk's coordinates. The desk is
  // 100vw, which takes in a classic scrollbar; the page is centred in the width beside it,
  // so the right edge and the middle come from that width rather than the desk's.
  const start = desk.getBoundingClientRect().left, view = document.documentElement.clientWidth;
  const inset = hero.getBoundingClientRect().left + parseFloat(getComputedStyle(hero).paddingLeft);
  edge = inset - start;
  far = view - inset - start;
  mid = view / 2 - start;
  half = boards[0].parentElement.offsetWidth / 2;
  pull = centred ? 0 : Math.min(1, Math.max(0, (innerWidth - NARROW) / (WIDE - NARROW)));

  // The mark is drawn at the display's own resolution, so it never blurs or dithers.
  scale = devicePixelRatio;
  pen.canvas.width = Math.round(SIZE[0] * scale);
  pen.canvas.height = Math.round(SIZE[1] * scale);
  shown.mark = null;
  spots.clear();
  placed = null;

  for (const blob of blobs) shape(blob);
}

// Where the live board's centre goes: the outer boards `pull` of the way from the middle
// to the column's edges, and straight lines between the three while the row slides.
function slot(pan) {
  const left = mid + (edge + half - mid) * pull, right = mid + (far - half - mid) * pull;
  return pan <= 1 ? left + (mid - left) * pan : mid + (right - mid) * (pan - 1);
}

// The blobs as the video draws them (docs/promo/work/scene.html: blob): a circle with
// three lobes and five smaller ones on it, fitted to the blob's box. Cut once per size;
// the CSS breathing turns the lobes, so no frame redraws them.
function shape(blob) {
  const w = blob.offsetWidth / 2, h = blob.offsetHeight / 2, seed = +blob.dataset.seed;
  const points = Array.from({ length: 72 }, (_, n) => {
    const a = n / 72 * Math.PI * 2;
    const q = (1 + 0.08 * Math.sin(3 * a + seed) + 0.05 * Math.sin(5 * a - seed * 1.3)) / 1.13;
    return `${(w + Math.cos(a) * q * w).toFixed(1)} ${(h + Math.sin(a) * q * h).toFixed(1)}`;
  });
  blob.style.clipPath = `path('M${points.join('L')}Z')`;
}

// Where the rings start for a switch on this board, relative to their layer. Measured
// on the first switch after a resize and kept: the row has always settled on the board
// by the keydown, so the key is where it was the time before, and nothing lays out
// mid-loop.
function spot(ring) {
  const origin = layer.getBoundingClientRect();
  const centre = el => {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2 - origin.x, y: r.y + r.height / 2 - origin.y, size: r.width };
  };
  return { key: centre(keys[ring.board][ring.key]), mark: centre(mark) };
}

function place(ring) {
  if (!spots.has(ring.board)) spots.set(ring.board, spot(ring));
  const { key, mark } = spots.get(ring.board);
  for (const [el, c] of [[keyRing, key], [markRing, mark]]) {
    el.setAttribute('cx', c.x);
    el.setAttribute('cy', c.y);
  }

  // From the rim of one ring to the rim of the other, as they are on the first frame.
  const dx = mark.x - key.x, dy = mark.y - key.y, len = Math.hypot(dx, dy);
  const a = key.size * 0.8 / len, b = 1 - mark.size * 0.8 / len;
  line.setAttribute('x1', key.x + dx * a);
  line.setAttribute('y1', key.y + dy * a);
  line.setAttribute('x2', key.x + dx * b);
  line.setAttribute('y2', key.y + dy * b);
  placed = ring.board;
}

// ---------------------------------------------------------------- one frame
const shown = { text: '', mark: null, pressed: [] };
const char = (ch, composing) => Object.assign(document.createElement('span'), { textContent: ch, className: composing ? 'composing' : '' });

function apply(s) {
  // The field changes a keystroke at a time and empties at the end of the loop. The
  // last `composing` characters are the input method's, still being built.
  const text = `${s.text.map(c => c.ch).join('')}|${s.composing}`;
  if (text !== shown.text) {
    const from = s.text.length - s.composing;
    typed.replaceChildren(...s.text.map((c, i) => char(c.ch, i >= from)));
    shown.text = text;
  }
  s.text.forEach((c, i) => put(typed.children[i], '--f', c.flash));
  put(typed, '--fade', s.fade);
  put(caret, '--on', s.caret ? 1 : 0);

  // Keys up that were down, then the keys down now.
  const pressed = s.keys.map(k => [keys[k.board][k.key], k]).filter(([el]) => el);
  for (const el of shown.pressed) if (!pressed.some(([p]) => p === el)) put(el, '--down', 0);
  for (const [el, k] of pressed) {
    put(el, '--down', k.down);
    el.classList.toggle('hot', k.hot);
  }
  shown.pressed = pressed.map(([el]) => el);

  // The hands: the row slides to centre the board they go to, and the veils trade.
  put(track, 'translate', `${Math.round(slot(s.pan) - first - pitch * s.pan)}px`);
  s.idle.forEach((idle, i) => {
    put(boards[i], '--idle', idle);
    put(boards[i].parentElement, 'translate', `0 calc(var(--rest) + ${idle.toFixed(3)} * (var(--sink) - var(--rest)))`);
  });

  put(rail, '--row', s.rail);

  const pose = `${s.mark.from} ${s.mark.to} ${s.mark.progress.toFixed(3)} ${s.mark.hot.toFixed(3)}`;
  if (pose !== shown.mark) {
    draw(pen, scale, s.mark, ink, coral);
    shown.mark = pose;
  }

  rings(s.ring);
}

// A dotted ring grows out of the key and out of the mark, both from the keydown frame,
// and a dotted line joins them — whole on that first frame, so neither ring reads as
// its own event.
function rings(ring) {
  put(layer, 'visibility', ring ? 'visible' : 'hidden');
  if (!ring) {
    placed = null;
    return;
  }

  if (placed !== ring.board) place(ring);
  const { key, mark } = spots.get(ring.board), grow = out(ring.grow);
  spread(keyRing, key.size, grow);
  spread(markRing, mark.size, grow);
  line.setAttribute('opacity', 0.9 * (1 - out(ring.line)));
}

// ---------------------------------------------------------------- the clock
// Plays only while someone can see it: on screen, in a visible tab, not paused, and
// motion welcome. It opens on the still, which is also all reduced motion ever shows.
// ?t=<seconds> holds one moment instead, for checking a frame by eye.
const hold = new URLSearchParams(location.search).get('t');
const still = matchMedia('(prefers-reduced-motion: reduce)');
let t = hold === null ? STILL : +hold, last = null, frame = 0, seen = false, paused = false;

function tick(now) {
  // A long gap (a stalled tab, a debugger) resumes where it was rather than jumping.
  if (last !== null) t = (t + Math.min(now - last, 100) / 1000) % LOOP;
  last = now;
  apply(state(t));
  if (pause.hidden) pause.hidden = false;
  frame = requestAnimationFrame(tick);
}

function sync() {
  const play = seen && !document.hidden && !paused && !still.matches && hold === null;
  hero.classList.toggle('playing', play);
  if (play && !frame) {
    last = null;
    frame = requestAnimationFrame(tick);
  }
  if (!play && frame) {
    cancelAnimationFrame(frame);
    frame = 0;
  }
  if (still.matches) {
    t = STILL;
    apply(state(t));
    pause.hidden = true;
  } else if (paused) {
    // No frame runs while paused, so tick() can't bring Play back after reduced motion lifts.
    pause.hidden = false;
  }
}

pause.addEventListener('click', () => {
  paused = !paused;
  pause.classList.toggle('paused', paused);
  pause.setAttribute('aria-label', paused ? 'Play the animation' : 'Pause the animation');
  sync();
});

measure();
apply(state(t));
new ResizeObserver(() => { measure(); apply(state(t)); }).observe(desk);
new IntersectionObserver(([e]) => { seen = e.isIntersecting; sync(); }).observe(hero);
document.addEventListener('visibilitychange', sync);
still.addEventListener('change', sync);
