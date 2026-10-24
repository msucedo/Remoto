// Rasterizes public/icon.svg and public/icon-maskable.svg to the PNG sizes the
// manifest and iOS expect, using headless Chrome. Run: npm run icons
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const pub = join(here, '..', 'public');
const chrome = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const work = mkdtempSync(join(tmpdir(), 'remoto-icons-'));

const jobs = [
  ['icon.svg', 'icon-192.png', 192, true],
  ['icon.svg', 'icon-512.png', 512, true],
  ['icon-maskable.svg', 'icon-maskable-192.png', 192, false],
  ['icon-maskable.svg', 'icon-maskable-512.png', 512, false],
  ['icon-maskable.svg', 'apple-touch-icon.png', 180, false],
];

try {
  for (const [src, out, size, transparent] of jobs) {
    const svg = readFileSync(join(pub, src), 'utf8');
    const html = `<!doctype html><html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style></head><body>${svg}</body></html>`;
    const page = join(work, 'page.html');
    writeFileSync(page, html);
    const shot = join(work, 'shot.png');
    execFileSync(chrome, [
      '--headless=new',
      '--disable-gpu',
      '--hide-scrollbars',
      `--user-data-dir=${join(work, 'profile')}`,
      `--window-size=${size},${size}`,
      ...(transparent ? ['--default-background-color=00000000'] : []),
      `--screenshot=${shot}`,
      `file://${page}`,
    ], { stdio: 'ignore' });
    copyFileSync(shot, join(pub, out));
    console.log(`wrote ${out}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
