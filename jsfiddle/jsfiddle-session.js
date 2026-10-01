// JSFiddle login session kept in a dedicated Playwright persistent profile, so
// jsfiddle-push.py never needs a hand-copied cookie file. Same pattern as
// sp-env's auth/pw-profile: the human logs in ONCE in a headed browser; after
// that everything runs headless from the saved profile.
//
//   node jsfiddle-session.js status   -> {"signedIn":true,"user":"..."}   exit 0 / 3
//   node jsfiddle-session.js login    -> headed Edge; waits (15 min) for the human to log in
//   node jsfiddle-session.js cookie   -> prints the Cookie header to STDOUT only; exit 3 if not signed in
//   node jsfiddle-session.js read <https://jsfiddle.net/user/slug/n/>
//                                     -> that fiddle's code + metadata as JSON, read signed in
//   node jsfiddle-session.js versions <https://jsfiddle.net/user/slug>
//                                     -> {"0":200,"1":200,"2":404}: signed-in status of each version
//
// `read` and `versions` are the read side for PRIVATE fiddles, which answer every
// anonymous GET with HTTP 500 (see jsfiddle-backend-http-access.md);
// jsfiddle-fetch.py falls back to them. They use context.request (no page is
// rendered, so the fiddle's code never runs) and never follow redirects, so a
// version saved by another account is reported (exit 6 / a 3xx status), not read.
// `read` prints a NARROWED bootstrap: {"config": {value, fiddle, header: {title,
// author}}}. config.session (csrfToken, account) and config.paths (render URL
// with a signed /show/ token) are dropped; no cookie or token is ever printed.
//
// Exit codes: 0 ok; 3 not signed in (run `login`); 4 anything else (browser
// missing, network); 7 profile busy (another login/push/fetch has it open);
// `read` only: 5 page not 200 even signed in (stderr `HTTP <status>`),
// 6 page redirects (stderr `REDIRECT <status> <location>`).
// Profile: ../_secrets/jsfiddle-profile (gitignored). The cookie is a
// credential: `cookie` exists so the push script can hold it in memory — never
// redirect it into a file or a log.
// Plain Node CommonJS. Playwright comes from this folder if installed, else
// from the sp-env skill's scripts/node_modules (installed by sp-env install.ps1).
'use strict';
const fs = require('fs');
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

class ProfileBusy extends Error {}

// A running browser holds <profile>/lockfile open exclusively (EBUSY on
// Windows); after a clean exit the file is gone. Checked before launching
// because a second Edge on a busy profile just hands off to the running one
// and Playwright reports a generic "browser has been closed" (verified
// 2026-10-01).
function assertProfileFree() {
  try {
    fs.closeSync(fs.openSync(path.join(profileDir, 'lockfile'), 'r+'));
  } catch (e) {
    if (e.code === 'ENOENT') return;
    if (['EBUSY', 'EPERM', 'EACCES'].includes(e.code)) throw new ProfileBusy();
    throw e;
  }
}

async function launch(headless) {
  assertProfileFree();
  const opts = { headless, viewport: headless ? undefined : null };
  try {
    // Installed Edge first: Google/GitHub sign-in is friendlier to a real browser.
    return await chromium.launchPersistentContext(profileDir, Object.assign({ channel: 'msedge' }, opts));
  } catch (e) {
    const msg = String(e && e.message);
    if (/ProcessSingleton|already in use/i.test(msg)) throw new ProfileBusy();
    // Bundled Chromium only when Edge isn't installed - never on an Edge profile
    // after some other failure (it would look signed out).
    if (!/is not found|not installed|Executable doesn't exist/i.test(msg)) throw e;
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

const getPage = (ctx, url) => ctx.request.get(url, { timeout: 60000, maxRedirects: 0 });

// One editor page, signed in -> only the fields the read side needs.
async function read(ctx, url) {
  const res = await getPage(ctx, url);
  const status = res.status();
  if (status >= 300 && status < 400) {
    console.error('REDIRECT ' + status + ' ' + (res.headers()['location'] || ''));
    return 6;
  }
  if (status !== 200) { console.error('HTTP ' + status); return 5; }
  const m = (await res.text()).match(/<script[^>]*id="editor-bootstrap"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('no editor-bootstrap JSON on ' + url + ' - page layout changed?');
  const c = JSON.parse(m[1]).config || {};
  const h = c.header || {};
  const out = { config: { value: c.value, fiddle: c.fiddle, header: { title: h.title, author: h.author } } };
  process.stdout.write(JSON.stringify(out) + '\n');
  return 0;
}

// Status of versions 0, 1, 2, ... up to the first 404 after 0 (capped).
async function versions(ctx, prefix) {
  const out = {};
  for (let n = 0; n <= 1000; n++) {
    out[n] = (await getPage(ctx, prefix + '/' + n + '/')).status();
    if (n > 0 && out[n] === 404) break;
  }
  process.stdout.write(JSON.stringify(out) + '\n');
  return 0;
}

async function main(cmd, arg) {
  if (!['status', 'login', 'cookie', 'read', 'versions'].includes(cmd)) {
    console.error('usage: node jsfiddle-session.js status|login|cookie|read <url>|versions <url>');
    return 4;
  }
  if ((cmd === 'read' || cmd === 'versions') && !/^https:\/\/jsfiddle\.net\/[\w./-]+$/.test(arg || '')) {
    console.error(cmd + ': expected a https://jsfiddle.net/<user>/<slug>/ URL');
    return 4;
  }
  const ctx = await launch(cmd !== 'login');
  try {
    let s = await session(ctx);
    if (cmd === 'status') { console.log(JSON.stringify(s)); return s.signedIn ? 0 : 3; }
    if (cmd === 'read' || cmd === 'versions') {
      if (!s.signedIn) { console.error('not signed in to JSFiddle - run: node jsfiddle-session.js login'); return 3; }
      return cmd === 'read' ? await read(ctx, arg) : await versions(ctx, arg.replace(/\/+$/, ''));
    }
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

main(process.argv[2], process.argv[3]).then((code) => process.exit(code), (e) => {
  const msg = String(e && e.message ? e.message : e);
  if (e instanceof ProfileBusy) {
    console.error('JSFIDDLE-SESSION-BUSY the JSFiddle profile (' + profileDir + ') is open in another '
      + 'process - a login, push or signed-in fetch still running, or a leftover Edge window on it. '
      + 'Wait for it to finish (or close that window) and retry.');
    process.exit(7);
  }
  console.error('JSFIDDLE-SESSION-FAIL ' + msg);
  process.exit(4);
});
