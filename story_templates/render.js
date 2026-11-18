// Renders story N (1-7) from week.html to out/story_N.jpg at 1080x1920 (drawn at 2x, then downscaled).
// Usage: node render.js 2 [extra query, e.g. "bg=assets/stock_snapping_veggies.jpg"]
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const n = process.argv[2] || '1';
  const extra = process.argv[3] ? '&' + process.argv[3] : '';
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: 2 });
  await p.goto('file://' + path.join(__dirname, 'week.html') + '?n=' + n + extra);
  await p.waitForTimeout(1500);
  await p.evaluate(() => document.fonts.ready);
  require('fs').mkdirSync(path.join(__dirname, 'out'), { recursive: true });
  await p.screenshot({ path: path.join(__dirname, 'out', 'story_' + n + '@2x.png') });
  await b.close();
})();
