// Headless check of the Playwright persistent profile against the dev site.
// Prints one JSON line: { authenticated, kind, ... }.
// kind: ok | auth_stale | browser_missing | profile_locked | network | timeout | tooling
// Exit codes: 0 = authenticated; 3 = auth_stale (interactive re-login is the fix);
//             4 = tooling/environment failure (re-login will NOT fix it); 2 = config missing.
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

function classifyError(e) {
  const m = String((e && e.message) || e);
  if (/Executable doesn't exist|browserType.launch.*not found|Please run.*playwright install/i.test(m)) return 'browser_missing';
  if (/ProcessSingleton|profile is already in use|already in use|Failed to create/i.test(m)) return 'profile_locked';
  if (/net::ERR_|ENOTFOUND|ECONNREFUSED|ECONNRESET|DNS/i.test(m)) return 'network';
  if (/Timeout .*exceeded|timed out/i.test(m)) return 'timeout';
  return 'tooling';
}

function finish(result) {
  console.log(JSON.stringify(result));
  process.exit(result.kind === 'ok' ? 0 : result.kind === 'auth_stale' ? 3 : 4);
}

(async () => {
  let ctx;
  try {
    ctx = await chromium.launchPersistentContext(profileDir, { headless: true });
  } catch (e) {
    return finish({ authenticated: false, kind: classifyError(e), error: String(e && e.message ? e.message : e) });
  }
  const page = ctx.pages()[0] || (await ctx.newPage());
  let result;
  try {
    await page.goto(site, { waitUntil: 'domcontentloaded', timeout: 60000 });
    // Give a possible silent SSO redirect chain a moment, then probe via REST (retry ~30s).
    const deadline = Date.now() + 30000;
    let probe = await probeAuth(page, site);
    while (!probe.authenticated && Date.now() < deadline && !/login\./.test(page.url() || '')) {
      await new Promise((r) => setTimeout(r, 3000));
      probe = await probeAuth(page, site);
    }
    if (probe.authenticated) {
      result = Object.assign({ kind: 'ok' }, probe);
    } else if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/.test(page.url() || '') ||
               /REST status (401|403)/.test(probe.reason || '')) {
      result = Object.assign({ kind: 'auth_stale' }, probe);
    } else {
      result = Object.assign({ kind: classifyError(new Error(probe.reason || 'probe failed')) }, probe);
      if (result.kind === 'ok') result.kind = 'tooling';
    }
  } catch (e) {
    result = { authenticated: false, kind: classifyError(e), finalUrl: page.url(), error: String(e && e.message ? e.message : e) };
  }
  await ctx.close().catch(() => {});
  finish(result);
})().catch((e) => {
  finish({ authenticated: false, kind: classifyError(e), error: String(e && e.message ? e.message : e) });
});
