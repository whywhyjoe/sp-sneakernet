// sp-env name resolver — THE one algorithm that turns logical names into URLs/paths.
// Used by all tools (provision, verify, deploy, run-harness). CommonJS, no deps.
//
// Algorithm:
//   1. env comes from env.local.json ("dev" | "prod"). env.local.json is REQUIRED.
//   2. Site: env.json's "site" alias (only "primary" is defined; default "primary")
//      resolves to tenants.local.json[env].siteUrl when the global skill is present
//      (dev machines — authoritative). On machines without tenants.local.json
//      (prod), env.local.json must supply siteUrl and roots.
//      If both sources define siteUrl and they differ → hard error (conflict).
//   3. Roots: tenants[env].roots, else env.local roots. A library/page entry names
//      a root logically ("code" | "devTools" | "lib" | "sitePages"); unknown roots
//      are rejected.
//   4. Paths in committed manifests must be safe relative paths: no URLs, no drive
//      letters, no leading slash, no "..", no encoded traversal, no backslashes.
//   5. Mirrors: tenants.mirrors overlaid with env.local mirrors (local wins).
//   6. Every resolved URL must start with the selected environment's siteUrl.
'use strict';
const fs = require('fs');
const path = require('path');

function stripSlash(u) { return String(u || '').replace(/\/+$/, ''); }

function assertSafeRelPath(p, label) {
  if (typeof p !== 'string' || p.length === 0) throw new Error(label + ': path must be a non-empty string');
  let decoded = p;
  for (let i = 0; i < 3; i++) {
    try { decoded = decodeURIComponent(decoded); } catch (e) { throw new Error(label + ': malformed encoding in path "' + p + '"'); }
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(decoded)) throw new Error(label + ': absolute URL/scheme not allowed in manifest: "' + p + '"');
  if (/^[a-zA-Z]:[\\/]/.test(decoded)) throw new Error(label + ': drive path not allowed in manifest: "' + p + '"');
  if (/\\/.test(decoded)) throw new Error(label + ': backslashes not allowed; use forward slashes: "' + p + '"');
  if (/^\//.test(decoded)) throw new Error(label + ': leading slash not allowed; paths are root-relative: "' + p + '"');
  const segs = decoded.split('/');
  if (segs.some((s) => s === '..' || s === '.')) throw new Error(label + ': path traversal not allowed: "' + p + '"');
  if (segs.some((s) => s.length === 0)) throw new Error(label + ': empty path segment in "' + p + '"');
  return decoded;
}

function resolveTarget(envJson, envLocal, tenants /* may be null on prod machines */) {
  if (!envLocal || typeof envLocal !== 'object') throw new Error('env.local.json is required (gitignored, per machine) — refusing to run without it.');
  const env = envLocal.env;
  if (env !== 'dev' && env !== 'prod') throw new Error('env.local.json "env" must be "dev" or "prod", got: ' + JSON.stringify(env));

  const tEnv = tenants ? tenants[env] : null;
  if (tenants && !tEnv) throw new Error('tenants.local.json has no "' + env + '" section');

  const siteAlias = envJson.site === undefined ? 'primary' : envJson.site;
  if (siteAlias !== 'primary') throw new Error('env.json "site" must be the alias "primary" (got "' + siteAlias + '"); real URLs never appear in manifests.');

  let siteUrl;
  if (tEnv) {
    siteUrl = stripSlash(tEnv.siteUrl);
    if (envLocal.siteUrl && stripSlash(envLocal.siteUrl).toLowerCase() !== siteUrl.toLowerCase()) {
      throw new Error('Conflict: env.local.json siteUrl (' + envLocal.siteUrl + ') differs from tenants.local.json ' + env + ' siteUrl — fix one; refusing to guess.');
    }
  } else {
    if (!envLocal.siteUrl) throw new Error('No tenants.local.json on this machine — env.local.json must supply siteUrl.');
    siteUrl = stripSlash(envLocal.siteUrl);
  }

  const roots = (tEnv && tEnv.roots) || envLocal.roots;
  if (!roots || typeof roots !== 'object') throw new Error('No roots available (tenants.local.json ' + env + '.roots or env.local.json roots).');

  const mirrors = Object.assign({}, (tenants && tenants.mirrors) || {}, envLocal.mirrors || {});
  delete mirrors._comment;

  function resolveEntry(entry, label, defaultRoot) {
    const rootKey = entry.root || defaultRoot;
    if (!rootKey) throw new Error(label + ': no "root" specified and no default applies');
    const rootPath = roots[rootKey];
    if (rootPath === undefined || rootPath === null || rootPath === '') {
      throw new Error(label + ': unknown root "' + rootKey + '" (known: ' + Object.keys(roots).filter((k) => k !== '_comment').join(', ') + ')');
    }
    const rel = assertSafeRelPath(entry.path, label);
    const url = siteUrl + '/' + stripSlash(rootPath) + '/' + rel;
    if (!url.toLowerCase().startsWith(siteUrl.toLowerCase() + '/')) throw new Error(label + ': resolved URL escaped the selected environment site — refusing.');
    const out = { root: rootKey, path: rel, url: url };
    if (mirrors[rootKey]) out.mirror = path.win32.join(mirrors[rootKey], rel.replace(/\//g, '\\'));
    return out;
  }

  const libraries = {};
  for (const [name, entry] of Object.entries(envJson.libraries || {})) {
    libraries[name] = resolveEntry(entry, 'libraries.' + name, null);
  }
  const pages = {};
  for (const [name, entry] of Object.entries(envJson.pages || {})) {
    pages[name] = Object.assign({}, entry, resolveEntry(entry, 'pages.' + name, 'sitePages'));
  }

  return { env: env, siteUrl: siteUrl, roots: roots, mirrors: mirrors, libraries: libraries, pages: pages, lists: envJson.lists || {}, flows: envJson.flows || [], deploy: envJson.deploy || {} };
}

function loadAndResolve(repoDir, spEnvDir) {
  spEnvDir = spEnvDir || path.resolve(__dirname, '..');
  const envJsonPath = path.join(repoDir, 'env.json');
  const envLocalPath = path.join(repoDir, 'env.local.json');
  if (!fs.existsSync(envJsonPath)) throw new Error('env.json missing at ' + envJsonPath);
  if (!fs.existsSync(envLocalPath)) throw new Error('env.local.json missing at ' + envLocalPath + ' — refusing to run (copy env.local.example.json and fill it in).');
  const envJson = JSON.parse(fs.readFileSync(envJsonPath, 'utf8'));
  const envLocal = JSON.parse(fs.readFileSync(envLocalPath, 'utf8'));
  const tenantsPath = path.join(spEnvDir, 'tenants.local.json');
  const tenants = fs.existsSync(tenantsPath) ? JSON.parse(fs.readFileSync(tenantsPath, 'utf8')) : null;
  return resolveTarget(envJson, envLocal, tenants);
}

module.exports = { resolveTarget, loadAndResolve, assertSafeRelPath };

if (require.main === module) {
  const repoDir = process.argv[2] || process.cwd();
  try {
    console.log(JSON.stringify(loadAndResolve(repoDir), null, 2));
  } catch (e) {
    console.error('RESOLVE-FAIL ' + String(e && e.message ? e.message : e));
    process.exit(1);
  }
}
