// The switch's dotted coral ring. hero.js draws it out of the key and the mark on every
// switch; any click on the page sets one off around the pointer, the way the menu bar
// mark pings when the layout changes.

import { RING } from './story.js';
import { SIZE } from './mark.js';

export const out = x => 1 - (1 - Math.min(1, x)) ** 3;

// One frame of a ring `size` across at its start, `grow` 0-1 already eased.
export function spread(el, size, grow) {
  el.setAttribute('r', size * (0.8 + 2.4 * grow));
  el.setAttribute('stroke-width', 3.5 * (1 - 0.5 * grow));
  el.setAttribute('stroke-dasharray', `0 ${7 + 3 * grow}`);
  el.setAttribute('opacity', 1 - grow);
}

// On its own layer over the page, which takes no clicks and goes when the ring does.
const still = matchMedia('(prefers-reduced-motion: reduce)');
const svg = 'http://www.w3.org/2000/svg';

function ping(x, y) {
  const layer = document.createElementNS(svg, 'svg');
  const circle = document.createElementNS(svg, 'circle');
  layer.classList.add('rings', 'ping');
  layer.setAttribute('aria-hidden', 'true');
  circle.setAttribute('cx', x);
  circle.setAttribute('cy', y);
  layer.append(circle);
  document.body.append(layer);

  const start = performance.now();
  const frame = now => {
    const t = (now - start) / 1000 / RING;
    if (t >= 1) return layer.remove();

    spread(circle, SIZE[0], out(t));
    requestAnimationFrame(frame);
  };
  spread(circle, SIZE[0], 0);
  requestAnimationFrame(frame);
}

// A plain click fetches the DMG into a hidden frame, so the page stays put and the ring
// is seen; GitHub serves it as an attachment, which downloads rather than shows. Any
// other click (a new tab, a modifier) is the link's own.
let frame;

function download(link) {
  if (!frame) {
    frame = document.createElement('iframe');
    frame.hidden = true;
    document.body.append(frame);
  }
  frame.src = link.href;
}

// Everything that takes a click pings, not just the downloads: one listener for the page.
const clickable = 'a[href], button, select, summary, label, [role=button]';

document.addEventListener('click', e => {
  const el = e.target.closest(clickable);
  if (!el) return;

  const plain = !(e.button || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey);
  if (plain && el.matches('a.button[href$=".dmg"]')) {
    e.preventDefault();
    download(el);
  }
  if (still.matches) return;

  // Enter clicks with no pointer: the ring leaves the element instead.
  if (e.detail) return ping(e.clientX, e.clientY);
  const r = el.getBoundingClientRect();
  ping(r.x + r.width / 2, r.y + r.height / 2);
});
