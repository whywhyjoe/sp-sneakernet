// Unit tests for resolve.js — run: node test-resolve.js
// Fixtures use example tenant names only; no real tenant data.
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
const bad = (p) => ({ site: 'primary', libraries: { x: { root: 'code', path: p } } });

// --- happy paths ---
ok('dev roots resolve through tenants', () => {
  const r = resolveTarget(envJson, { env: 'dev' }, tenants);
  assert.strictEqual(r.libraries.scripts.url, 'https://devtenant.sharepoint.example/sites/DevSite/Nested/Code/apps/pilot');
  assert.strictEqual(r.libraries.scripts.mirror, 'C:\\mirror\\code\\apps\\pilot');
  assert.strictEqual(r.pages.app.url, 'https://devtenant.sharepoint.example/sites/DevSite/SitePages/pilot.aspx');
});
ok('prod roots differ from dev for the same manifest', () => {
  const r = resolveTarget(envJson, { env: 'prod', siteUrl: tenants.prod.siteUrl, roots: tenants.prod.roots }, null);
  assert.strictEqual(r.libraries.scripts.url, 'https://prodtenant.sharepoint.example/sites/ProdSite/code/apps/pilot');
});
ok('equivalent siteUrl accepted', () => {
  resolveTarget(envJson, { env: 'dev', siteUrl: tenants.dev.siteUrl.toUpperCase() + '/' }, tenants);
});

// --- authoritative precedence (Sol re-review finding 2) ---
ok('blank local roots/mirrors are treated as omitted (committed example is safe)', () => {
  const local = { env: 'dev', siteUrl: '', roots: { sitePages: '', code: '', devTools: '', lib: '' }, mirrors: { code: '', devTools: '' } };
  const r = resolveTarget(envJson, local, tenants);
  assert.strictEqual(r.libraries.scripts.mirror, 'C:\\mirror\\code\\apps\\pilot', 'global mirrors must survive blank local mirrors');
  assert.deepStrictEqual(r.roots, tenants.dev.roots);
});
ok('identical explicit local values accepted', () => {
  resolveTarget(envJson, { env: 'dev', roots: { code: 'Nested/Code' }, mirrors: { code: 'C:\\mirror\\code\\' } }, tenants);
});
rejects('local root conflicting with authoritative global rejected', () =>
  resolveTarget(envJson, { env: 'dev', roots: { code: 'Other/Code' } }, tenants), /Conflict: env\.local\.json roots\.code/);
rejects('local mirror conflicting with authoritative global rejected', () =>
  resolveTarget(envJson, { env: 'dev', mirrors: { code: 'D:\\elsewhere' } }, tenants), /Conflict: env\.local\.json mirrors\.code/);
rejects('local root key unknown to authoritative global rejected', () =>
  resolveTarget(envJson, { env: 'dev', roots: { extra: 'X' } }, tenants), /not defined in authoritative/);
rejects('siteUrl conflict rejected', () =>
  resolveTarget(envJson, { env: 'dev', siteUrl: 'https://other.sharepoint.example/sites/X' }, tenants), /Conflict/);

// --- path safety (Sol re-review finding 1) ---
rejects('.. traversal', () => resolveTarget(bad('a/../b'), { env: 'dev' }, tenants), /traversal/);
rejects('encoded traversal (1x)', () => resolveTarget(bad('a/%2e%2e/b'), { env: 'dev' }, tenants), /traversal|percent/);
ok('deeply encoded traversal rejected at any depth (1..6 encodings)', () => {
  let p = '../x';
  for (let i = 1; i <= 6; i++) {
    p = encodeURIComponent(p === '../x' && i === 1 ? '../x' : p);
    assert.throws(() => resolveTarget(bad(p), { env: 'dev' }, tenants), /traversal|percent|stabilize/, 'depth ' + i + ' must be rejected: ' + p);
  }
});
rejects('lone percent-encoding rejected outright', () => resolveTarget(bad('a/%41b'), { env: 'dev' }, tenants), /percent/);
rejects('malformed percent rejected', () => resolveTarget(bad('a/%zz'), { env: 'dev' }, tenants), /percent|malformed/);
rejects('absolute URL', () => resolveTarget(bad('https://evil.example/x'), { env: 'dev' }, tenants), /scheme/);
rejects('drive path', () => resolveTarget(bad('C:/evil'), { env: 'dev' }, tenants), /scheme|drive/);
rejects('leading slash', () => resolveTarget(bad('/abs'), { env: 'dev' }, tenants), /leading slash/);
rejects('backslash', () => resolveTarget(bad('a\\b'), { env: 'dev' }, tenants), /backslash/i);
rejects('unknown root', () => resolveTarget({ site: 'primary', libraries: { x: { root: 'nope', path: 'a' } } }, { env: 'dev' }, tenants), /unknown root/);

// --- root values are validated too (configured root cannot escape the web) ---
rejects('root with traversal rejected', () => {
  const evil = JSON.parse(JSON.stringify(tenants)); evil.dev.roots.code = '../OtherWeb';
  return resolveTarget(envJson, { env: 'dev' }, evil);
}, /traversal/);
rejects('root with encoded traversal rejected', () => {
  const evil = JSON.parse(JSON.stringify(tenants)); evil.dev.roots.code = '%252e%252e/OtherWeb';
  return resolveTarget(envJson, { env: 'dev' }, evil);
}, /traversal|percent/);
rejects('absolute root rejected', () => {
  const evil = JSON.parse(JSON.stringify(tenants)); evil.dev.roots.code = '/OtherWeb';
  return resolveTarget(envJson, { env: 'dev' }, evil);
}, /leading slash/);

// --- misc contract ---
rejects('site must be alias', () => resolveTarget({ site: 'https://x.example', libraries: {} }, { env: 'dev' }, tenants), /alias/);
rejects('env.local required', () => resolveTarget(envJson, null, tenants), /env\.local\.json is required/);
rejects('bad env value', () => resolveTarget(envJson, { env: 'staging' }, tenants), /"dev" or "prod"/);

console.log('ALL ' + n + ' RESOLVER TESTS PASSED');
