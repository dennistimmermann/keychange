// The launch video's halftone drop shadow (docs/promo/work/scene.html: shade, halftone,
// dots), printed once per box size. A soft shadow of the box is screened at 45°: each
// dot's area follows the shadow's density, so dots are full where it is dense and shrink
// to nothing with distance — no hard edge, and no dot cut in half.
//
// The video blurs a canvas and reads it back; here the blur is worked out instead (the
// rounded box's distance field through a Gaussian's CDF), which needs no canvas and
// cannot be skewed by a browser that adds noise to canvas reads. The dots go out as an
// SVG, which stays sharp at any zoom and has no canvas size limit on a long page.
// style.css tints it and offsets it: the ink and the drop stay CSS's, so a press
// still only moves a finished image.

const SHADED = '.cards article, .settings article, .legal article, .button, .bar, .popover, .field, .board';

const CELL = 4;         // dot pitch in CSS px: the video's 11 at the page's third of its scale
const BLUR = 3.5;       // the shadow's softness, a Gaussian's sigma
const DENSITY = 0.62;   // how dark it gets where it is solid
const BLEED = 12;       // room past the box for the tail and a whole dot; style.css's inset
const REACH = 16;       // the furthest any --drop moves the dots, down and right

const cdf = x => 1 / (1 + Math.exp(-1.702 * x));
const hash = (i, j) => { const s = Math.sin(i * 127.1 + j * 311.7) * 43758.5453; return s - Math.floor(s); };

// Signed distance to a w x h box with corner radius r, from its centre: negative inside.
function distance(x, y, w, h, r) {
  const qx = Math.abs(x) - w / 2 + r, qy = Math.abs(y) - h / 2 + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

// The dots for a w x h box, as an SVG the size of the box plus BLEED all round.
function print(w, h, r) {
  const W = w + 2 * BLEED, H = h + 2 * BLEED;

  // The screen at 45°: a square grid a pitch apart, turned, is every other point of a
  // finer upright one. Centred on the box, so its dots fall the same on every side.
  const c = CELL * Math.SQRT1_2, U = Math.ceil(W / 2 / c), V = Math.ceil(H / 2 / c);
  const inside = (x, y, size) => distance(x, y, w, h, r) < -size;
  const runs = new Map();
  for (let v = -V; v <= V; v++) for (let u = -U; u <= U; u++) {
    if ((u + v) & 1) continue;

    const x = u * c, y = v * c, d = distance(x, y, w, h, r);
    if (d < -REACH * Math.SQRT2 - CELL) continue;

    const a = DENSITY * cdf(-d / BLUR);
    if (a < 0.03) continue;

    // A dot the box covers at every drop never shows: the whole top and left of the
    // shadow, and its middle. Checking the drop's corners is enough, the box is convex.
    const size = CELL * 0.74 * Math.sqrt(a) * (0.94 + 0.12 * hash(u, v));
    if (inside(x, y, size) && inside(x + REACH, y, size) && inside(x, y + REACH, size) && inside(x + REACH, y + REACH, size)) continue;

    // Dots as round caps on empty strokes, one path per size: a third of the bytes
    // of a circle each.
    const width = (Math.round(size * 40) / 20).toFixed(2);
    runs.set(width, (runs.get(width) ?? '') + `M${(x + W / 2).toFixed(1)} ${(y + H / 2).toFixed(1)}h0`);
  }
  const paths = [...runs].map(([width, d]) => `<path stroke-width='${width}' d='${d}'/>`).join('');

  // Quoted with ' inside and " around, so only the brackets and # need escaping.
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 ${W} ${H}' preserveAspectRatio='none'>`
    + `<g stroke='#000' stroke-linecap='round'>${paths}</g></svg>`;
  return `url("data:image/svg+xml,${svg.replace(/[<>#%]/g, encodeURIComponent)}")`;
}

// Printed on first sight of each size, and again only when a box changes size.
const seen = new WeakMap();
const observer = new ResizeObserver(entries => {
  for (const { target, borderBoxSize: [box] } of entries) {
    const w = Math.round(box.inlineSize), h = Math.round(box.blockSize), size = `${w}x${h}`;
    if (!w || !h || seen.get(target) === size) continue;

    seen.set(target, size);
    const r = Math.min(parseFloat(getComputedStyle(target).borderTopLeftRadius) || 0, w / 2, h / 2);
    target.style.setProperty('--shade', print(w, h, r));
    target.classList.add('printed');
  }
});
for (const el of document.querySelectorAll(SHADED)) observer.observe(el);
