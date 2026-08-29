// Verify op — drift report vs env.json: every declared list, column, page, and
// the scripts folder must exist. passed === true means ZERO drift.
(function () {
  'use strict';
  window.__spEnvOp = {
    name: 'verify',
    run: function (ctx) {
      var sp = ctx.sp, env = ctx.env;
      var drift = [], checked = [];
      function serverRel(url) { return new URL(url).pathname; }

      function checkList(def) {
        var list = sp.web.lists.getByTitle(def.title);
        return list.select('Title')().then(function () {
          checked.push('list: ' + def.title);
          var chain = Promise.resolve();
          (def.columns || []).forEach(function (col) {
            chain = chain.then(function () {
              return list.fields.getByInternalNameOrTitle(col.name)().then(function () {
                checked.push('field: ' + def.title + '.' + col.name);
              }).catch(function () { drift.push('missing field: ' + def.title + '.' + col.name); });
            });
          });
          return chain;
        }).catch(function () { drift.push('missing list: ' + def.title); });
      }

      function checkPath(rel, label) {
        return sp.web.getFileByServerRelativePath(rel).select('Exists')().then(function () {
          checked.push(label);
        }).catch(function () { drift.push('missing ' + label); });
      }
      function checkFolder(rel, label) {
        return sp.web.getFolderByServerRelativePath(rel).select('Exists')().then(function (f) {
          if (f.Exists === false) { drift.push('missing ' + label); } else { checked.push(label); }
        }).catch(function () { drift.push('missing ' + label); });
      }

      var chain = Promise.resolve();
      Object.keys(env.lists || {}).forEach(function (k) {
        chain = chain.then(function () { return checkList(env.lists[k]); });
      });
      Object.keys(env.pages || {}).forEach(function (k) {
        chain = chain.then(function () { return checkPath(serverRel(env.pages[k].url), 'page: ' + env.pages[k].path); });
      });
      chain = chain.then(function () { return checkFolder(serverRel(env.libraries.scripts.url), 'scripts folder'); });

      return chain.then(function () {
        return { passed: drift.length === 0, results: { drift: drift, checked: checked.length } };
      });
    }
  };
})();
