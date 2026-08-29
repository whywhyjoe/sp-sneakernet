// sp-env harness runner — loaded by the harness page's Script Editor Web Part.
// Loads a named op script (provision.js / verify.js / test-*.js) from its own
// library folder, runs it, posts {Suite, Passed, Results, GitSha} to TestRuns,
// renders the outcome with a "copy results JSON" button (the prod/JSFiddle
// bridge), and signals completion for Playwright via #sp-env-harness-done.
// Plain script, no ES modules. PnPjs via window.pnp2 with the setup() line.
(function () {
  'use strict';
  var baseUrl = (function () {
    var src = document.currentScript && document.currentScript.src;
    return src ? src.slice(0, src.lastIndexOf('/')) : null;
  })();

  var root = document.getElementById('sp-env-harness') || (function () {
    var d = document.createElement('div'); d.id = 'sp-env-harness';
    document.body.appendChild(d); return d;
  })();
  root.innerHTML = '<h3>sp-env harness</h3><div id="sp-env-status">loading…</div>' +
    '<div id="sp-env-buttons"></div><pre id="sp-env-out" style="white-space:pre-wrap"></pre>';
  function status(t) { document.getElementById('sp-env-status').textContent = t; }

  function loadScript(url) {
    return new Promise(function (res, rej) {
      var s = document.createElement('script');
      s.src = url;
      s.onload = function () { res(); };
      s.onerror = function () { rej(new Error('failed to load ' + url)); };
      document.head.appendChild(s);
    });
  }

  function finish(result) {
    window.__spEnvResult = result;
    document.getElementById('sp-env-out').textContent = JSON.stringify(result, null, 2);
    var btn = document.createElement('button');
    btn.textContent = 'copy results JSON';
    btn.onclick = function () { navigator.clipboard.writeText(JSON.stringify(result, null, 2)); };
    root.appendChild(btn);
    var done = document.createElement('div');
    done.id = 'sp-env-harness-done';
    done.setAttribute('data-passed', String(result.passed === true));
    root.appendChild(done);
    status(result.passed ? 'PASSED: ' + result.suite : 'FAILED: ' + result.suite);
  }

  function postTestRun(env, result) {
    var body = {
      Title: result.suite + ' @ ' + new Date().toISOString(),
      Suite: result.suite,
      Passed: result.passed === true,
      Results: JSON.stringify(result.results).slice(0, 60000),
      GitSha: env.gitSha || ''
    };
    return window.pnp2.sp.web.lists.getByTitle('TestRuns').items.add(body)
      .then(function () { return true; })
      .catch(function (e) {
        result.results.testRunsPostError = String(e && e.message ? e.message : e);
        return false;
      });
  }

  function runOp(env, opFile) {
    window.__spEnvOp = null;
    status('running ' + opFile + ' …');
    return loadScript(baseUrl + '/' + opFile).then(function () {
      var op = window.__spEnvOp;
      if (!op || typeof op.run !== 'function') { throw new Error(opFile + ' did not register window.__spEnvOp'); }
      return op.run({ sp: window.pnp2.sp, env: env, base: baseUrl });
    }).then(function (r) {
      var result = { suite: (window.__spEnvOp && window.__spEnvOp.name) || opFile, passed: r.passed === true, results: r.results || {} };
      return postTestRun(env, result).then(function () { finish(result); });
    }).catch(function (e) {
      finish({ suite: opFile, passed: false, results: { error: String(e && e.message ? e.message : e) } });
    });
  }

  if (!baseUrl) { status('cannot determine own script URL'); return; }
  fetch(baseUrl + '/resolved-env.json', { credentials: 'include' })
    .then(function (r) { if (!r.ok) { throw new Error('resolved-env.json HTTP ' + r.status + ' — run deploy first'); } return r.json(); })
    .then(function (env) {
      var pnpUrl = env.libraries.pnp2 && env.libraries.pnp2.url;
      var chain = window.pnp2 ? Promise.resolve() : loadScript(pnpUrl);
      return chain.then(function () {
        if (!window.pnp2) { throw new Error('window.pnp2 missing after loading ' + pnpUrl); }
        window.pnp2.sp.setup({ sp: { baseUrl: window._spPageContextInfo.webAbsoluteUrl } });
        var params = new URLSearchParams(window.location.search);
        var ops = ['provision.js', 'verify.js', 'test-smoke.js'];
        var buttons = document.getElementById('sp-env-buttons');
        ops.forEach(function (o) {
          var b = document.createElement('button');
          b.textContent = 'run ' + o;
          b.style.marginRight = '6px';
          b.onclick = function () { runOp(env, o); };
          buttons.appendChild(b);
        });
        if (params.get('run')) { return runOp(env, params.get('run')); }
        status('ready — pick an op');
      });
    })
    .catch(function (e) { status('harness init failed: ' + String(e && e.message ? e.message : e)); });
})();
