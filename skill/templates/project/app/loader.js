// App loader — the single script the app page's SEWP points at. Bootstraps
// the runtime (resolved-env.json + pnp2 + setup) and then loads app.js.
// Plain script, no ES modules.
(function () {
  'use strict';
  var baseUrl = (function () {
    var src = document.currentScript && document.currentScript.src;
    return src ? src.slice(0, src.lastIndexOf('/')) : null;
  })();
  if (!baseUrl) { return; }

  function loadScript(url) {
    return new Promise(function (res, rej) {
      var s = document.createElement('script');
      s.src = url;
      s.onload = function () { res(); };
      s.onerror = function () { rej(new Error('failed to load ' + url)); };
      document.head.appendChild(s);
    });
  }

  // AMD trap: modern SP pages define an AMD loader, so a UMD bundle injected
  // late never sets window.pnp2 unless define is hidden during the load.
  function loadScriptNoAmd(url) {
    var savedDefine = window.define;
    window.define = undefined;
    return loadScript(url).then(function () {
      window.define = savedDefine;
    }, function (e) {
      window.define = savedDefine;
      throw e;
    });
  }

  fetch(baseUrl + '/resolved-env.json', { credentials: 'include' })
    .then(function (r) { if (!r.ok) { throw new Error('resolved-env.json HTTP ' + r.status); } return r.json(); })
    .then(function (env) {
      var chain = window.pnp2 ? Promise.resolve() : loadScriptNoAmd(env.libraries.pnp2.url);
      return chain.then(function () {
        if (!window.pnp2) { throw new Error('window.pnp2 missing after loading ' + env.libraries.pnp2.url); }
        // _spPageContextInfo is not reliable on modern pages; resolved-env siteUrl is.
        var baseUrl2 = (window._spPageContextInfo && window._spPageContextInfo.webAbsoluteUrl) || env.siteUrl;
        window.pnp2.sp.setup({ sp: { baseUrl: baseUrl2 } });
        window.__spEnvApp = { env: env, base: baseUrl, sp: window.pnp2.sp };
        return loadScript(baseUrl + '/app.js');
      });
    })
    .catch(function (e) {
      var d = document.createElement('div');
      d.id = 'sp-env-app-error';
      d.textContent = 'app bootstrap failed: ' + String(e && e.message ? e.message : e);
      document.body.appendChild(d);
    });
})();
