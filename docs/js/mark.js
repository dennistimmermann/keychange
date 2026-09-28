// The menu bar mark, MenuBarMark.frame ported to canvas without the dim and the badge,
// which the hero never shows. Two 9.2 x 6.9 plates at 80% overlap, the front one lower
// left, scaled 18/8.68 into points. A swap slides them past each other; their alphas
// cross 1.0 <-> 0.4, the old code is knocked out by the midpoint and the new one knocked
// in after it. Each plate punches a 0.4 rim out of whatever is under it.
//
// Drawn as a mask and then filled, the way AppKit tints a template image: solid colour
// at the display's own resolution, so it stays as crisp as the real one.

const K = 18 / 8.68;
const W = 9.2 * K, H = 6.9 * K, R = 2 * K, PUNCH = 0.4 * K;
const FRONT = [0, 3.69], BACK = [1.84 * K, 0.83];   // top-left corners, y down

export const SIZE = [23, 18];                       // points: the status item's image

// `scale` is canvas pixels per point. `mark` is story.js's: the codes swapped between,
// the swap's 0-1, and how much of `coral` lies over the `ink`.
export function draw(ctx, scale, { from, to, progress, hot }, ink, coral) {
  const swap = from === to ? 1 : progress;
  const lerp = (a, b) => [a[0] + (b[0] - a[0]) * swap, a[1] + (b[1] - a[1]) * swap];

  ctx.save();
  ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
  ctx.scale(scale, scale);
  ctx.fillStyle = '#000';

  const plate = ([x, y], alpha, code, fraction) => {
    ctx.globalCompositeOperation = 'destination-out';
    ctx.beginPath();
    ctx.roundRect(x - PUNCH, y - PUNCH, W + 2 * PUNCH, H + 2 * PUNCH, R + PUNCH);
    ctx.fill();

    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = alpha;
    ctx.beginPath();
    ctx.roundRect(x, y, W, H, R);
    ctx.fill();
    ctx.globalAlpha = 1;
    if (fraction <= 0) return;

    // Centred on the ink rather than the font's metrics, which drift at this size.
    ctx.globalCompositeOperation = 'destination-out';
    ctx.globalAlpha = fraction;
    ctx.font = `700 ${4.8 * K}px -apple-system, system-ui, sans-serif`;
    ctx.letterSpacing = `${-0.1 * K}px`;
    const m = ctx.measureText(code);
    ctx.fillText(code, x + W / 2 + (m.actualBoundingBoxLeft - m.actualBoundingBoxRight) / 2,
                 y + H / 2 + (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent) / 2);
    ctx.globalAlpha = 1;
  };
  const old = () => plate(lerp(FRONT, BACK), 1 - 0.6 * swap, from, Math.max(0, 1 - 2 * swap));
  const next = () => plate(lerp(BACK, FRONT), 0.4 + 0.6 * swap, to, Math.max(0, 2 * swap - 1));

  // The plate headed to the front paints on top from the midpoint on.
  if (swap < 0.5) { next(); old(); } else { old(); next(); }

  // The mask is done; colour it like a template image.
  ctx.globalCompositeOperation = 'source-in';
  ctx.fillStyle = ink;
  ctx.fillRect(0, 0, SIZE[0], SIZE[1]);
  if (hot > 0) {
    ctx.globalCompositeOperation = 'source-atop';
    ctx.globalAlpha = hot;
    ctx.fillStyle = coral;
    ctx.fillRect(0, 0, SIZE[0], SIZE[1]);
  }
  ctx.restore();
}
