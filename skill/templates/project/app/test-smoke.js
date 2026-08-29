// Smoke test op — reads items from the project's first data list (any list
// except TestRuns) and reports what an app page would render.
(function () {
  'use strict';
  window.__spEnvOp = {
    name: 'test-smoke',
    run: function (ctx) {
      var sp = ctx.sp, env = ctx.env;
      var dataKey = Object.keys(env.lists || {}).filter(function (k) {
        return env.lists[k].title !== 'TestRuns';
      })[0];
      if (!dataKey) { return Promise.resolve({ passed: false, results: { error: 'no data list in env.json' } }); }
      var title = env.lists[dataKey].title;
      return sp.web.lists.getByTitle(title).items.top(20)().then(function (items) {
        return {
          passed: true,
          results: {
            list: title,
            itemCount: items.length,
            titles: items.map(function (i) { return i.Title; })
          }
        };
      }).catch(function (e) {
        return { passed: false, results: { list: title, error: String(e && e.message ? e.message : e) } };
      });
    }
  };
})();
