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

  fetch(baseUrl + '/resolved-env.json', { credentials: 'include' })
    .then(function (r) { if (!r.ok) { throw new Error('resolved-env.json HTTP ' + r.status); } return r.json(); })
    .then(function (env) {
      var chain = window.pnp2 ? Promise.resolve() : loadScript(env.libraries.pnp2.url);
      return chain.then(function () {
        window.pnp2.sp.setup({ sp: { baseUrl: window._spPageContextInfo.webAbsoluteUrl } });
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
