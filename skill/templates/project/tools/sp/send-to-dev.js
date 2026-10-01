// PROD → DEV via JSFiddle, with a human in the loop. Packages what dev needs
// into one payload, checks it for secrets and tenant facts, then opens the
// JSFiddle editor PREFILLED with it (jsfiddle.net/api/post — nothing is saved).
// The human reviews it in the browser, presses Ctrl+S while logged in, and
// sends dev the URL. Nothing leaves this machine until that Ctrl+S.
//
//   node tools/sp/send-to-dev.js results [file]     results JSON (default: clipboard)
//   node tools/sp/send-to-dev.js diff               uncommitted changes vs HEAD, incl. new files
//   node tools/sp/send-to-dev.js files [paths...]   whole files (default: the whole repo) —
//                                                   for a first send, when dev has nothing to diff
// Options: --title "<text>"   --dry-run (write the payload file, don't open a browser)
//          --allow-warnings   (send despite WARN findings; BLOCK findings always stop)
//
// Payload = line 1 `// SNEAKERNET {json header}`, line 2 a `throw` guard (the
// prefilled editor autoruns the JS panel - nothing may execute), then the body. In files
// mode each file starts with a `// FILE: {json}` line (path, sha256 of the
// LF-normalized content, eol, final newline) so dev's jsfiddle-unpack.py can
// rebuild them byte-exact and verify them. Plain Node, no dependencies.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFileSync, spawnSync } = require('child_process');

const PREFILL = 'https://jsfiddle.net/api/post/library/pure/';
const MAX_FILE = 1024 * 1024;
const NEVER = [/(^|\/)\.git\//, /(^|\/)node_modules\//, /(^|\/)_secrets\//, /(^|\/)auth\//,
  /(^|\/)pw-profile\//, /\.local\.json$/, /(^|\/)env\.local\.json$/, /\.(pfx|pem|key|cer|p12)$/i];

function die(msg) { console.error('send-to-dev: ' + msg); process.exit(1); }

function git(args, opts = {}) {
  const r = spawnSync('git', args, Object.assign({ encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 }, opts));
  if (r.error) return { ok: false, out: '', err: String(r.error.message) };
  return { ok: r.status === 0, status: r.status, out: r.stdout || '', err: r.stderr || '' };
}

// ---------- args ----------
const argv = process.argv.slice(2);
const kind = argv.shift();
if (!['results', 'diff', 'files'].includes(kind)) {
  die('usage: node send-to-dev.js results [file] | diff | files [paths...]  [--title T] [--dry-run] [--allow-warnings]');
}
const opts = { title: null, dryRun: false, allowWarnings: false, rest: [] };
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--title') opts.title = argv[++i];
  else if (argv[i] === '--dry-run') opts.dryRun = true;
  else if (argv[i] === '--allow-warnings') opts.allowWarnings = true;
  else opts.rest.push(argv[i]);
}

// ---------- repo context ----------
const top = git(['rev-parse', '--show-toplevel']);
const root = top.ok ? path.resolve(top.out.trim()) : process.cwd();
const head = git(['rev-parse', '--short', 'HEAD'], { cwd: root });
const sha = head.ok ? head.out.trim() : null;
const branch = (git(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: root }).out || '').trim() || null;
const project = (() => {
  for (const dir of [process.cwd(), root]) {
    try { return JSON.parse(fs.readFileSync(path.join(dir, 'env.json'), 'utf8')).project; } catch (_) { /* next */ }
  }
  return path.basename(process.cwd());
})();

const rel = (abs) => path.relative(root, abs).split(path.sep).join('/');
const excluded = (p) => NEVER.some((re) => re.test(p));
const isBinary = (buf) => buf.subarray(0, 8000).includes(0);

// Files git would track here (tracked + untracked, minus ignored); plain walk if not a repo.
function candidateFiles(abs) {
  if (top.ok) {
    const r = git(['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', abs], { cwd: root });
    if (!r.ok) die('git ls-files failed: ' + r.err);
    return [...new Set(r.out.split('\0').filter(Boolean))].filter((p) => fs.existsSync(path.join(root, p)));
  }
  const out = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (!excluded(rel(p) + '/')) walk(p); } else out.push(rel(p));
    }
  })(abs);
  return out;
}

// ---------- build body ----------
const notes = [];
let body = '';
let count = 0;

if (kind === 'results') {
  let text;
  if (opts.rest[0]) text = fs.readFileSync(opts.rest[0], 'utf8');
  else if (process.platform === 'win32') {
    text = execFileSync('powershell', ['-NoProfile', '-Command', 'Get-Clipboard -Raw'], { encoding: 'utf8' });
  } else die('pass the results file (clipboard read is Windows-only)');
  try { JSON.parse(text); } catch (_) {
    die('that is not JSON. Click "copy results JSON" on the harness page first (or pass the file).');
  }
  body = text.trim() + '\n';
  count = 1;
} else if (kind === 'diff') {
  if (!top.ok) die('not a git repo — use `files` to send whole files instead.');
  const parts = [];
  if (sha) {
    const d = git(['diff', 'HEAD', '--no-color', '--no-ext-diff'], { cwd: root });
    if (!d.ok) die('git diff failed: ' + d.err);
    parts.push(d.out);
    count += (d.out.match(/^diff --git /gm) || []).length;
    if (/^Binary files /m.test(d.out)) notes.push('binary changes are NOT carried by the diff — send those files another way');
  }
  // New files (and every file when there is no commit yet), without touching the index.
  const others = sha ? git(['ls-files', '-z', '--others', '--exclude-standard'], { cwd: root }).out.split('\0').filter(Boolean)
    : candidateFiles(root);
  for (const p of others) {
    if (excluded(p)) { notes.push('skipped (never sent): ' + p); continue; }
    const buf = fs.readFileSync(path.join(root, p));
    if (isBinary(buf)) { notes.push('skipped binary: ' + p); continue; }
    const d = git(['diff', '--no-color', '--no-index', '--', '/dev/null', p], { cwd: root });
    if (d.status !== 1) die('git diff --no-index failed for ' + p + ': ' + d.err);
    parts.push(d.out);
    count++;
  }
  body = parts.join('');
  if (!body.trim()) die('no changes against HEAD. For a first send of existing files use: node tools/sp/send-to-dev.js files');
} else {
  const targets = opts.rest.length ? opts.rest : [root];
  const list = [];
  for (const t of targets) {
    const abs = path.resolve(t);
    if (!fs.existsSync(abs)) die('no such path: ' + t);
    if (path.isAbsolute(path.relative(root, abs)) || path.relative(root, abs).startsWith('..')) die('outside the repo: ' + t);
    if (fs.statSync(abs).isDirectory()) list.push(...candidateFiles(abs)); else list.push(rel(abs));
  }
  for (const p of [...new Set(list)].sort()) {
    if (excluded(p)) { notes.push('skipped (never sent): ' + p); continue; }
    const buf = fs.readFileSync(path.join(root, p));
    if (isBinary(buf)) { notes.push('skipped binary: ' + p); continue; }
    if (buf.length > MAX_FILE) { notes.push('skipped >1 MB: ' + p); continue; }
    const raw = buf.toString('utf8');
    const lf = raw.replace(/\r\n/g, '\n');
    const meta = {
      path: p,
      sha256: crypto.createHash('sha256').update(lf, 'utf8').digest('hex'),
      eol: raw.includes('\r\n') ? 'crlf' : 'lf',
      finalNewline: lf.endsWith('\n'),
    };
    // A content line that itself looks like a marker gets one extra leading
    // backslash (reversed by jsfiddle-unpack.py); the hash is of the original.
    const escaped = lf.replace(/^(\\*)(\/\/ (?:FILE:|SNEAKERNET) )/gm, '\\$1$2');
    body += '// FILE: ' + JSON.stringify(meta) + '\n' + escaped + (meta.finalNewline ? '' : '\n');
    count++;
  }
  if (!count) die('no sendable files found.');
}

// ---------- scan: tenant facts + secrets ----------
const findings = [];
const lines = body.split('\n');
function scan(re, level, why) {
  lines.forEach((l, i) => { if (re.test(l)) findings.push({ level, why, line: i + 2, text: l.trim().slice(0, 120) }); });
}
function localValues(file) {
  const vals = [];
  try {
    (function walk(v) {
      if (typeof v === 'string') { if (v.length >= 8 && /[./:\\]/.test(v)) vals.push(v); }
      else if (v && typeof v === 'object') Object.values(v).forEach(walk);
    })(JSON.parse(fs.readFileSync(file, 'utf8')));
  } catch (_) { /* absent */ }
  return vals;
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const tenantVals = new Set([...localValues(path.join(process.cwd(), 'env.local.json')), ...localValues(path.join(root, 'env.local.json'))]);
for (const v of tenantVals) {
  scan(new RegExp(esc(v), 'i'), 'BLOCK', 'value from env.local.json (tenant fact)');
  try { const h = new URL(v).host; if (h) scan(new RegExp(esc(h), 'i'), 'BLOCK', 'tenant host from env.local.json'); } catch (_) { /* not a URL */ }
}
scan(/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'BLOCK', 'private key');
scan(/\b(client_?secret|password|passwd|api_?key|access_?token|refresh_?token|connection_?string)\b\s*[:=]\s*['"][^'"\s]{8,}/i, 'BLOCK', 'secret-looking assignment');
scan(/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, 'BLOCK', 'JWT / bearer token');
scan(/\b(AccountKey|SharedAccessSignature|sig)=[A-Za-z0-9%+/=]{20,}/, 'BLOCK', 'storage key / SAS');
scan(/\b[a-z0-9-]+(-my|-admin)?\.sharepoint\.com\b/i, 'WARN', 'a SharePoint tenant host');
scan(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, 'WARN', 'an email address');

const blocks = findings.filter((f) => f.level === 'BLOCK');
const warns = findings.filter((f) => f.level === 'WARN');
for (const f of findings.slice(0, 40)) console.error(`${f.level}  payload line ${f.line}: ${f.why}\n       ${f.text}`);
if (findings.length > 40) console.error(`... ${findings.length - 40} more findings`);
if (blocks.length) die(blocks.length + ' BLOCK finding(s). Fiddles are public — remove these from the files (or leave the files out) and rerun.');
if (warns.length && !opts.allowWarnings) {
  die(warns.length + ' WARN finding(s). Have the human check each one; rerun with --allow-warnings only if they are fine to publish.');
}

// ---------- write payload + prefill page, open the browser ----------
const header = { kind, project, sha, branch, count, created: new Date().toISOString() };
// The prefilled editor AUTORUNS the JS panel: line 2 throws so no payload code
// ever executes (a payload that doesn't parse can't run at all).
const GUARD = 'throw new Error("sneakernet payload: data, not code - do not run");';
const payload = '// SNEAKERNET ' + JSON.stringify(header) + '\n' + GUARD + '\n' + body;
const title = opts.title || `${project}: ${kind}${sha ? ' @' + sha : ''} (sneakernet)`;
const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
const outDir = path.join(os.tmpdir(), 'sneakernet-send');
fs.mkdirSync(outDir, { recursive: true });
const payloadFile = path.join(outDir, `${project}-${kind}-${stamp}.txt`);
fs.writeFileSync(payloadFile, payload, 'utf8');

const h = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const page = `<!doctype html><meta charset="utf-8"><title>Send to dev - ${h(project)}</title>
<body style="font:15px system-ui;margin:2em">
<p>Opening JSFiddle with <b>${count}</b> ${kind === 'files' ? 'file(s)' : kind === 'diff' ? 'changed file(s)' : 'result set'} from <b>${h(project)}</b>…</p>
<p>In the editor: <b>review</b> the JavaScript panel, make sure you are <b>logged in</b>, press <b>Ctrl+S</b>,
then send dev the URL from the address bar (it should look like jsfiddle.net/&lt;user&gt;/&lt;slug&gt;/&lt;n&gt;/).</p>
<form id="f" method="post" action="${PREFILL}">
<input type="hidden" name="title" value="${h(title)}">
<input type="hidden" name="description" value="${h('sneakernet ' + kind + ' from ' + project + (sha ? ' @ ' + sha : ''))}">
<textarea name="js" style="display:none">${h(payload)}</textarea>
<button type="submit">Open in JSFiddle</button></form>
<script>document.getElementById('f').submit();</script></body>`;
const pageFile = payloadFile.replace(/\.txt$/, '.html');
fs.writeFileSync(pageFile, page, 'utf8');

console.log(`${kind}: ${count} item(s), ${payload.length} chars${notes.length ? '\n  ' + notes.join('\n  ') : ''}`);
console.log('payload: ' + payloadFile);
if (payload.length > 1024 * 1024) console.log('note: payload is over 1 MB - JSFiddle may refuse to save it; send fewer files per fiddle.');
if (opts.dryRun) { console.log('dry run - not opening the browser. Prefill page: ' + pageFile); process.exit(0); }

const open = process.platform === 'win32' ? ['cmd', ['/c', 'start', '""', '"' + pageFile + '"']]
  : process.platform === 'darwin' ? ['open', [pageFile]] : ['xdg-open', [pageFile]];
spawnSync(open[0], open[1], { stdio: 'ignore', windowsVerbatimArguments: process.platform === 'win32' });
console.log('Opened the prefilled JSFiddle editor in the browser. Human: review, log in, Ctrl+S, send dev the URL.');
console.log('Both temp files contain the payload - delete ' + outDir + ' when done.');
