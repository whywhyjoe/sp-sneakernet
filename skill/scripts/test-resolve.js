// Unit tests for resolve.js — run: node test-resolve.js
// Fixtures use example.com tenant names only; no real tenant data.
'use strict';
const assert = require('assert');
const { resolveTarget } = require('./resolve');

const tenants = {
  dev: {
    siteUrl: 'https://devtenant.sharepoint.example/sites/DevSite',
    roots: { sitePages: 'SitePages', code: 'Nested/Code', devTools: 'Nested/Dev', lib: 'Nested/Code/lib' },
  },
  prod: {
    siteUrl: 'https://prodtenant.sharepoint.example/sites/ProdSite',
    roots: { sitePages: 'SitePages', code: 'code', devTools: 'dev', lib: 'Code/lib' },
  },
  mirrors: { code: 'C:\\mirror\\code', devTools: 'C:\\mirror\\dev' },
};

const envJson = {
  project: 'pilot',
  site: 'primary',
  libraries: { scripts: { root: 'code', path: 'apps/pilot' } },
  pages: { app: { path: 'pilot.aspx', loader: 'loader.js' } },
};

let n = 0;
function ok(name, fn) { fn(); n++; console.log('PASS ' + name); }
function rejects(name, fn, re) {
  assert.throws(fn, re, name + ': expected rejection ' + re);
  n++; console.log('PASS ' + name);
}

// 1. dev happy path: nested root, mirror mapping, page under sitePages default root
ok('dev roots resolve through tenants', () => {
  const r = resolveTarget(envJson, { env: 'dev' }, tenants);
  assert.strictEqual(r.libraries.scripts.url, 'https://devtenant.sharepoint.example/sites/DevSite/Nested/Code/apps/pilot');
  assert.strictEqual(r.libraries.scripts.mirror, 'C:\\mirror\\code\\apps\\pilot');
  assert.strictEqual(r.pages.app.url, 'https://devtenant.sharepoint.example/sites/DevSite/SitePages/pilot.aspx');
});

// 2. same manifest resolves differently for prod (different root nesting)
ok('prod roots differ from dev for the same manifest', () => {
  const r = resolveTarget(envJson, { env: 'prod', siteUrl: tenants.prod.siteUrl, roots: tenants.prod.roots }, null);
  assert.strictEqual(r.libraries.scripts.url, 'https://prodtenant.sharepoint.example/sites/ProdSite/code/apps/pilot');
});

// 3. prod machine without tenants.local.json uses env.local values
ok('no tenants.local.json → env.local supplies site and roots', () => {
  const r = resolveTarget(envJson, { env: 'prod', siteUrl: tenants.prod.siteUrl, roots: tenants.prod.roots }, null);
  assert.strictEqual(r.env, 'prod');
});

// 4. conflict between env.local siteUrl and tenants is rejected
rejects('siteUrl conflict rejected', () =>
  resolveTarget(envJson, { env: 'dev', siteUrl: 'https://other.sharepoint.example/sites/X' }, tenants), /Conflict/);

// 5. matching (case-insensitive, trailing slash) siteUrl is NOT a conflict
ok('equivalent siteUrl accepted', () => {
  resolveTarget(envJson, { env: 'dev', siteUrl: tenants.dev.siteUrl.toUpperCase() + '/' }, tenants);
});

// 6-11. unsafe manifest paths rejected
const bad = (p) => ({ site: 'primary', libraries: { x: { root: 'code', path: p } } });
rejects('.. traversal', () => resolveTarget(bad('a/../b'), { env: 'dev' }, tenants), /traversal/);
rejects('encoded traversal', () => resolveTarget(bad('a/%2e%2e/b'), { env: 'dev' }, tenants), /traversal/);
rejects('absolute URL', () => resolveTarget(bad('https://evil.example/x'), { env: 'dev' }, tenants), /scheme/);
rejects('drive path', () => resolveTarget(bad('C:/evil'), { env: 'dev' }, tenants), /scheme|drive/);
rejects('leading slash', () => resolveTarget(bad('/abs'), { env: 'dev' }, tenants), /leading slash/);
rejects('backslash', () => resolveTarget(bad('a\\b'), { env: 'dev' }, tenants), /backslash/i);

// 12. unknown root rejected
rejects('unknown root', () => resolveTarget({ site: 'primary', libraries: { x: { root: 'nope', path: 'a' } } }, { env: 'dev' }, tenants), /unknown root/);

// 13. raw URL in "site" rejected
rejects('site must be alias', () => resolveTarget({ site: 'https://x.example', libraries: {} }, { env: 'dev' }, tenants), /alias/);

// 14. missing env.local rejected
rejects('env.local required', () => resolveTarget(envJson, null, tenants), /env\.local\.json is required/);

// 15. bad env value rejected
rejects('bad env value', () => resolveTarget(envJson, { env: 'staging' }, tenants), /"dev" or "prod"/);

console.log('ALL ' + n + ' RESOLVER TESTS PASSED');
