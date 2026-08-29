// Creation/repair of the Playwright persistent profile for dev.
// If the profile is already authenticated it detects that immediately and exits
// with no human involvement; otherwise the HEADED browser waits for the human to
// complete the Microsoft login once. Plain Node CommonJS — no ES modules.
'use strict';
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');
const { probeAuth } = require('./sp-probe');

const root = path.resolve(__dirname, '..');
const tenantsPath = path.join(root, 'tenants.local.json');
if (!fs.existsSync(tenantsPath)) {
  console.error('tenants.local.json missing at ' + tenantsPath + ' — refusing to run.');
  process.exit(2);
}
const tenants = JSON.parse(fs.readFileSync(tenantsPath, 'utf8'));
const site = tenants.dev.siteUrl;
const profileDir = path.join(root, 'auth', 'pw-profile');

(async () => {
  const ctx = await chromium.launchPersistentContext(profileDir, {
    headless: false,
    viewport: null,
    args: ['--start-maximized'],
  });
  const page = ctx.pages()[0] || (await ctx.newPage());
  await page.goto(site, { waitUntil: 'domcontentloaded', timeout: 120000 });
  console.log('[pw-profile] Waiting for authenticated SharePoint page — complete the Microsoft sign-in in the opened browser (choose "Stay signed in": Yes). Timeout 15 minutes.');
  const deadline = Date.now() + 15 * 60 * 1000;
  let info = null;
  let lastLogged = 0;
  while (!info) {
    if (Date.now() > deadline) throw new Error('Timed out waiting for login (15 min). Last URL: ' + page.url());
    if (page.isClosed()) throw new Error('Browser window was closed before login completed.');
    const probe = await probeAuth(page, site);
    if (probe.authenticated) info = probe;
    if (!info) {
      if (Date.now() - lastLogged > 30000) {
        console.log('[pw-profile] still waiting… current URL: ' + page.url());
        lastLogged = Date.now();
      }
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  console.log('PW-PROFILE-OK ' + JSON.stringify(info));
  await ctx.close();
})().catch((e) => {
  console.error('PW-PROFILE-FAIL ' + String(e && e.message ? e.message : e));
  process.exit(1);
});
