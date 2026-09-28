// Builds docs/assets/demo.webp and demo.gif, the README's loop, from the landing page's
// own hero. The README shows the WebP; the GIF stays for anywhere that can't.
//
//     node make-demo.mjs            on the page's paper, blobs and all
//     node make-demo.mjs --clear    on nothing: no paper, no blobs, transparent
//
// A capture, not a recording: hero.js holds any moment with ?t=<seconds>, so each frame
// is the page loaded at that moment. A held page never plays, so the blobs stay still
// too, and the last frame joins the first the way story.js's loop does.

import { createServer } from 'node:http';
import { readFile, readdir, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, extname } from 'node:path';
import { execSync, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { LOOP, SWITCHES } from './docs/js/story.js';

const DOCS = new URL('./docs/', import.meta.url).pathname;
const FPS = 20;                    // 5 GIF centiseconds a frame, exactly
const WIDTH = 620;                 // the README's <img width>, in CSS px: shot at 2x, halved
const MARGIN = 28;                 // air above the menu bar card; the lilac blob is cut
const DESK = 0;                    // air between the field and the keyboards
const CLEAR = process.argv.includes('--clear');
// Under 1060 px the hero is one column, so the demo and the live keyboard share the
// window's centre.
const VIEWPORT = { width: 1000, height: 1400 };

// Every switch falls 0.025 s past a 20 fps grid, so the grid starts there: each keydown
// gets its own frame. Frame times are (k + phase) / FPS, exact in binary at the switches.
const phase = SWITCHES[0].at * FPS % 1;
const frames = Math.round(LOOP * FPS);
for (const s of SWITCHES) {
  if (Math.abs((s.at * FPS - phase) % 1) > 1e-9) throw new Error(`switch at ${s.at} s is off the frame grid`);
}

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2',
};
const server = createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname.replace(/\/$/, '/index.html');
  try {
    const body = await readFile(join(DOCS, decodeURIComponent(path)));
    res.writeHead(200, { 'content-type': TYPES[extname(path)] ?? 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
}).listen(0);
const origin = `http://localhost:${server.address().port}`;

const require = createRequire(import.meta.url);
const { chromium } = require(`${execSync('npm root -g').toString().trim()}/@playwright/cli/node_modules/playwright-core`);
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: VIEWPORT, deviceScaleFactor: 2 });
// Only the page itself: the release-tag fetch has nothing to do with the demo.
await page.route(url => !url.href.startsWith(origin), route => route.abort());

async function load(t) {
  await page.goto(`${origin}/?t=${t}&centred`);
  // The copy sits above the demo in one column; hidden, it leaves the page as it is. One
  // column also stacks the keyboards right under the field, which a frame of its own
  // needs to breathe: the desk comes down, the demo and its rings unchanged.
  await page.addStyleTag({ content: `.hero-copy { visibility: hidden; } .desk { margin-top: ${DESK}px; }` });
  // Ink labels on nothing vanish on a dark README, so each moves down onto its board's
  // white, into a margin above the keys grown by --head and in line with them, and the
  // desk rises into the room the labels leave. At z 1 it sits over the board and under
  // the veil.
  if (CLEAR) await page.addStyleTag({ content: `
    html, body { background: none; }
    .blob { display: none; }
    .desk {
      --head: 16px;
      margin-top: -24px;
      height: calc(26px + var(--head) + 3.35 * var(--u) + var(--dissolve));
    }
    .board { height: calc(4.84 * var(--u) + 4px + var(--head)); }
    .caps { top: calc(26px + var(--head)); }
    .keyboard p {
      position: relative;
      z-index: 1;
      translate: 0 calc(18px + 0.245 * var(--u) + var(--head) / 2);
      padding-left: calc(2px + 0.49 * var(--u));
      font-size: 9px;
    }` });
  await page.evaluate(() => document.fonts.ready);
}

// From just above the menu bar card to the foot of the desk, centred on the window.
await load(0);
const clip = await page.evaluate(([width, margin]) => {
  const top = document.querySelector('.bar').getBoundingClientRect().top - margin;
  const bottom = document.querySelector('.desk').getBoundingClientRect().bottom;
  return { x: (innerWidth - width) / 2, y: top + scrollY, width, height: Math.round(bottom - top) };
}, [WIDTH, MARGIN]);

const dir = await mkdtemp(join(tmpdir(), 'demo-'));
for (let k = 0; k < frames; k++) {
  await load((k + phase) / FPS);
  await page.screenshot({ path: join(dir, `${String(k).padStart(4, '0')}.png`), clip, fullPage: true, omitBackground: CLEAR });
}
await browser.close();
server.close();

// Halved with straight alpha, an edge blends with the black of the clear pixels beside it
// and comes out a grey line, so a clear frame is scaled premultiplied.
const scale = CLEAR
  ? `premultiply=inplace=1,scale=${WIDTH}:-1:flags=lanczos,unpremultiply=inplace=1`
  : `scale=${WIDTH}:-1:flags=lanczos`;

// One palette for the whole loop, so no colour shifts between frames or at the seam. GIF
// has no partial transparency, so a clear GIF's soft edges snap to on or off at half.
execFileSync('ffmpeg', [
  '-loglevel', 'error', '-y', '-framerate', String(FPS), '-i', join(dir, '%04d.png'),
  '-filter_complex', `${scale},split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128`,
  '-loop', '0', join(DOCS, 'assets', 'demo.gif'),
], { stdio: 'inherit' });
// ffmpeg keeps unchanged pixels between frames by making them transparent, which a clear
// GIF can't spare, so it writes every frame whole; gifsicle finds the changed parts again.
if (CLEAR) execFileSync('gifsicle', ['-O3', '--batch', join(DOCS, 'assets', 'demo.gif')], { stdio: 'inherit' });

// The WebP keeps what the GIF can't: real alpha, so the soft edges stay soft on a light
// README and a dark one alike. The same frames, halved the same way, kept as RGBA and
// handed over whole; img2webp finds what changed itself. It always stores alpha
// losslessly, and at all 256 levels that alone made the file nearly as big as the GIF;
// 16 levels still read as soft edges (GIF has two) and halve it.
const halved = join(dir, 'halved');
await mkdir(halved);
execFileSync('ffmpeg', [
  '-loglevel', 'error', '-y', '-framerate', String(FPS), '-i', join(dir, '%04d.png'),
  '-vf', `${scale},lutrgb=a='floor(val/16)*16+15*gte(val,255)'`, '-pix_fmt', 'rgba', join(halved, '%04d.png'),
], { stdio: 'inherit' });
const shots = (await readdir(halved)).sort().map(f => join(halved, f));
execFileSync('img2webp', [
  '-loop', '0', '-d', String(1000 / FPS), '-lossy', '-q', '75', ...shots,
  '-o', join(DOCS, 'assets', 'demo.webp'),
], { stdio: 'inherit' });

await rm(dir, { recursive: true });
console.log(`docs/assets/demo.webp and demo.gif: ${frames} frames at ${FPS} fps, ${WIDTH}x${Math.round(clip.height)}`);
