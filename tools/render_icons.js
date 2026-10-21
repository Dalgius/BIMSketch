// Genera le icone PNG (usate su macOS) a partire dalle SVG.
// Uso: NODE_PATH=$(npm root -g) node tools/render_icons.js
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const dir = path.join(__dirname, '..', 'src', 'bimsketch', 'icons');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 64, height: 64 } });
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.svg'))) {
    const svg = fs.readFileSync(path.join(dir, file), 'utf8');
    const name = path.basename(file, '.svg');
    for (const size of [16, 24]) {
      const sized = svg.replace('width="24" height="24"', `width="${size}" height="${size}"`);
      await page.setContent(`<html><body style="margin:0;background:transparent">${sized}</body></html>`);
      const out = path.join(dir, size === 16 ? `${name}_16.png` : `${name}.png`);
      await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    }
  }
  await browser.close();
  console.log('Icone generate in', dir);
})();
