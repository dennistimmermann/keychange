// Builds docs/assets/demo.gif, the README's loop, from the landing page's own hero.
//
//     node make-demo.mjs
//
// A capture, not a recording: hero.js holds any moment with ?t=<seconds>, so each frame
// is the page loaded at that moment. A held page never plays, so the blobs stay still
// too, and the last frame joins the first the way story.js's loop does.

import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
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
  await page.screenshot({ path: join(dir, `${String(k).padStart(4, '0')}.png`), clip, fullPage: true });
}
await browser.close();
server.close();

// One palette for the whole loop, so no colour shifts between frames or at the seam.
execFileSync('ffmpeg', [
  '-loglevel', 'error', '-y', '-framerate', String(FPS), '-i', join(dir, '%04d.png'),
  '-filter_complex', `scale=${WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a`,
  '-loop', '0', join(DOCS, 'assets', 'demo.gif'),
], { stdio: 'inherit' });
await rm(dir, { recursive: true });
console.log(`docs/assets/demo.gif: ${frames} frames at ${FPS} fps, ${WIDTH}x${Math.round(clip.height)}`);
