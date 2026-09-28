// node render.mjs stills 0.5 1.8 ...   -> stills/t-<s>.png
// node render.mjs video                 -> video.mp4 (no audio) + timeline.json
import { createRequire } from 'node:module';
import { spawn, execSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = execSync('npm root -g').toString().trim();
const { chromium } = createRequire(import.meta.url)(`${root}/@playwright/cli/node_modules/playwright-core`);

// Served, not file://, so the panel capture can be read back off a canvas.
const types = { '.html': 'text/html', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };
const server = http.createServer(async (req, res) => {
  try {
    const file = path.join(here, decodeURIComponent(req.url.split('?')[0]));
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
}).listen(0);
const port = server.address().port;

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
page.on('console', m => console.log('page:', m.text()));
page.on('pageerror', e => console.error('page error:', e.message));
await page.goto(`http://localhost:${port}/scene.html`);
await page.evaluate(() => window.ready);
const T = await page.evaluate(() => window.T);
const shot = () => page.locator('#stage').screenshot({ type: 'png' });

const [mode, ...args] = process.argv.slice(2);
if (mode === 'stills') {
  mkdirSync(path.join(here, 'stills'), { recursive: true });
  for (const t of args) {
    await page.evaluate(t => window.render(t), Number(t));
    writeFileSync(path.join(here, 'stills', `t-${t}.png`), await shot());
  }
} else {
  writeFileSync(path.join(here, 'timeline.json'), JSON.stringify(T, null, 2));
  const frames = Math.round(T.end * T.fps);
  const ff = spawn('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(T.fps),
    '-i', '-', '-c:v', 'libx264', '-crf', '10', '-preset', 'medium', '-pix_fmt', 'yuv444p',
    path.join(here, 'video.mp4')], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let f = 0; f < frames; f++) {
    await page.evaluate(t => window.render(t), f / T.fps);
    if (!ff.stdin.write(await shot())) await new Promise(r => ff.stdin.once('drain', r));
    if (f % 60 === 0) console.log(`frame ${f}/${frames}`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
await browser.close();
server.close();
