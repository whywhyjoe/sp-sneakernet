// The app. Template version: reads the project's first data list and renders
// its items. Replace with real app logic; keep the no-ES-modules rule and use
// ctx from window.__spEnvApp (set by loader.js).
(function () {
  'use strict';
  var ctx = window.__spEnvApp;
  if (!ctx) { return; }
  var env = ctx.env, sp = ctx.sp;

  var root = document.getElementById('sp-env-app-root') || (function () {
    var d = document.createElement('div'); d.id = 'sp-env-app-root';
    document.body.appendChild(d); return d;
  })();

  var dataKey = Object.keys(env.lists || {}).filter(function (k) {
    return env.lists[k].title !== 'TestRuns';
  })[0];
  var title = dataKey ? env.lists[dataKey].title : null;
  if (!title) { root.textContent = 'no data list configured'; return; }

  root.innerHTML = '<h2>' + env.project + '</h2><div id="sp-env-app-status">loading ' + title + '…</div><ul id="sp-env-app-items"></ul>';
  sp.web.lists.getByTitle(title).items.top(50)().then(function (items) {
    var ul = document.getElementById('sp-env-app-items');
    items.forEach(function (i) {
      var li = document.createElement('li');
      li.textContent = i.Title + (i.Status ? ' — ' + i.Status : '');
      ul.appendChild(li);
    });
    document.getElementById('sp-env-app-status').textContent = items.length + ' item(s) from "' + title + '"';
    // Marker for Playwright render verification:
    root.setAttribute('data-sp-env-rendered', String(items.length));
  }).catch(function (e) {
    document.getElementById('sp-env-app-status').textContent = 'load failed: ' + String(e && e.message ? e.message : e);
  });
})();
