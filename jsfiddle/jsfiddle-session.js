// JSFiddle login session kept in a dedicated Playwright persistent profile, so
// jsfiddle-push.py never needs a hand-copied cookie file. Same pattern as
// sp-env's auth/pw-profile: the human logs in ONCE in a headed browser; after
// that everything runs headless from the saved profile.
//
//   node jsfiddle-session.js status   -> {"signedIn":true,"user":"..."}   exit 0 / 3
//   node jsfiddle-session.js login    -> headed Edge; waits (15 min) for the human to log in
//   node jsfiddle-session.js cookie   -> prints the Cookie header to STDOUT only; exit 3 if not signed in
//
// Exit codes: 0 ok; 3 not signed in (run `login`); 4 anything else (profile
// locked, browser missing, network). Profile: ../_secrets/jsfiddle-profile
// (gitignored). The cookie is a credential: `cookie` exists so the push script
// can hold it in memory — never redirect it into a file or a log.
// Plain Node CommonJS. Playwright comes from this folder if installed, else
// from the sp-env skill's scripts/node_modules (installed by sp-env install.ps1).
'use strict';
const path = require('path');
const os = require('os');

function loadPlaywright() {
  try { return require('playwright'); } catch (_) { /* fall through */ }
  const spEnv = path.join(os.homedir(), '.claude', 'skills', 'sp-env', 'scripts', 'node_modules', 'playwright');
  try { return require(spEnv); } catch (_) {
    console.error('playwright not found (looked in ./node_modules and ' + spEnv + '). Install the sp-env skill or `npm i playwright` here.');
    process.exit(4);
  }
}

const { chromium } = loadPlaywright();
const BASE = 'https://jsfiddle.net';
const profileDir = path.resolve(__dirname, '..', '_secrets', 'jsfiddle-profile');

async function launch(headless) {
  const opts = { headless, viewport: headless ? undefined : null };
  try {
    // Installed Edge first: Google/GitHub sign-in is friendlier to a real browser.
    return await chromium.launchPersistentContext(profileDir, Object.assign({ channel: 'msedge' }, opts));
  } catch (e) {
    if (/ProcessSingleton|already in use/i.test(String(e && e.message))) throw e;
    return await chromium.launchPersistentContext(profileDir, opts);
  }
}

// Signed-in state, read the same way the editor does: the bootstrap JSON.
async function session(ctx) {
  const res = await ctx.request.get(BASE + '/', { timeout: 30000 });
  const m = (await res.text()).match(/<script[^>]*id="editor-bootstrap"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('no editor-bootstrap JSON on ' + BASE + '/ (status ' + res.status() + ') - page layout changed?');
  const s = (JSON.parse(m[1]).config || {}).session || {};
  return { signedIn: !!s.signedIn, user: (s.user && (s.user.username || s.user.name)) || null };
}

async function main(cmd) {
  if (!['status', 'login', 'cookie'].includes(cmd)) {
    console.error('usage: node jsfiddle-session.js status|login|cookie');
    return 4;
  }
  const ctx = await launch(cmd !== 'login');
  try {
    let s = await session(ctx);
    if (cmd === 'status') { console.log(JSON.stringify(s)); return s.signedIn ? 0 : 3; }
    if (cmd === 'cookie') {
      if (!s.signedIn) { console.error('not signed in to JSFiddle - run: node jsfiddle-session.js login'); return 3; }
      const cookies = await ctx.cookies(BASE);
      process.stdout.write(cookies.map((c) => c.name + '=' + c.value).join('; ') + '\n');
      return 0;
    }
    // login
    if (s.signedIn) { console.log('JSFIDDLE-LOGIN-OK ' + JSON.stringify(s)); return 0; }
    const page = ctx.pages()[0] || (await ctx.newPage());
    await page.goto(BASE + '/user/login/', { waitUntil: 'domcontentloaded', timeout: 120000 });
    console.log('[jsfiddle] Log in to JSFiddle in the opened browser window. Waiting up to 15 minutes...');
    const deadline = Date.now() + 15 * 60 * 1000;
    while (!s.signedIn) {
      if (Date.now() > deadline) throw new Error('timed out waiting for login (15 min)');
      if (page.isClosed()) throw new Error('browser window closed before login completed');
      await new Promise((r) => setTimeout(r, 3000));
      s = await session(ctx);
    }
    console.log('JSFIDDLE-LOGIN-OK ' + JSON.stringify(s));
    return 0;
  } finally {
    await ctx.close();
  }
}

main(process.argv[2]).then((code) => process.exit(code), (e) => {
  console.error('JSFIDDLE-SESSION-FAIL ' + String(e && e.message ? e.message : e));
  process.exit(4);
});
