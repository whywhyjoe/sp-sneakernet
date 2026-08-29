// DEV-ONLY: drives the harness page in Playwright (persistent profile), runs a
// named op script, waits for completion, and reads the latest TestRuns rows
// back via REST — the closed-loop verification step. Node CommonJS.
// Usage: node run-harness.js <op>   (op: provision | verify | test-smoke | any op .js)
'use strict';
const path = require('path');
const os = require('os');
const { loadAndResolve } = require('./resolve');

const repo = path.resolve(__dirname, '..', '..');
const op = process.argv[2];
if (!op) { console.error('usage: node run-harness.js <op>  e.g. provision | verify | test-smoke'); process.exit(2); }
const opFile = op.endsWith('.js') ? op : op + '.js';
const timeoutMs = Number(process.env.SP_ENV_HARNESS_TIMEOUT || 120000);

const skillScripts = path.join(os.homedir(), '.claude', 'skills', 'sp-env', 'scripts');
const { chromium } = require(path.join(skillScripts, 'node_modules', 'playwright'));

(async () => {
  const resolved = loadAndResolve(repo);
  const profileDir = path.join(os.homedir(), '.claude', 'skills', 'sp-env', 'auth', 'pw-profile');
  const url = resolved.pages.harness.url + '?run=' + encodeURIComponent(opFile) + '&auto=1';

  const ctx = await chromium.launchPersistentContext(profileDir, { headless: true });
  const page = ctx.pages()[0] || (await ctx.newPage());
  let out;
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    if (/login\.microsoftonline\.com/.test(page.url())) {
      throw new Error('AUTH-STALE: login redirect — run sp-env auth-refresh.ps1 and retry.');
    }
    await page.waitForSelector('#sp-env-harness-done', { timeout: timeoutMs });
    const result = await page.evaluate(() => window.__spEnvResult);
    const rows = await page.evaluate(async (site) => {
      const r = await fetch(site + "/_api/web/lists/getbytitle('TestRuns')/items?$select=Id,Suite,Passed,Results,GitSha,Created&$orderby=Id desc&$top=5",
        { headers: { accept: 'application/json;odata=nometadata' }, credentials: 'include' });
      if (!r.ok) return { error: 'TestRuns read failed: HTTP ' + r.status };
      return (await r.json()).value;
    }, resolved.siteUrl);
    out = { op: opFile, harnessResult: result, testRunsLatest: rows };
    console.log('RUN-HARNESS-RESULT ' + JSON.stringify(out, null, 2));
  } finally {
    await ctx.close().catch(() => {});
  }
  const passed = out && out.harnessResult && out.harnessResult.passed === true;
  process.exit(passed ? 0 : 1);
})().catch((e) => {
  console.error('RUN-HARNESS-FAIL ' + String(e && e.message ? e.message : e));
  process.exit(1);
});
