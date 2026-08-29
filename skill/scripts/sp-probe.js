// Shared auth probe: runs a cookie-authenticated REST call from inside the page.
// Works on any SharePoint page (modern pages don't reliably expose _spPageContextInfo).
'use strict';

async function probeAuth(page, siteUrl) {
  const finalUrl = page.url();
  if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/.test(finalUrl)) {
    return { authenticated: false, finalUrl: finalUrl, reason: 'login redirect' };
  }
  try {
    const data = await page.evaluate(async (site) => {
      const base = site.replace(/\/+$/, '');
      const opts = { headers: { accept: 'application/json;odata=nometadata' }, credentials: 'include' };
      const r = await fetch(base + '/_api/web?$select=Title,Url', opts);
      if (!r.ok) return { ok: false, status: r.status };
      const web = await r.json();
      let user = null;
      try {
        const ru = await fetch(base + '/_api/web/currentuser?$select=Title,LoginName', opts);
        if (ru.ok) user = await ru.json();
      } catch (e) { /* user info is best-effort */ }
      return { ok: true, title: web.Title, webUrl: web.Url, user: user && user.Title, login: user && user.LoginName };
    }, siteUrl);
    if (data && data.ok) {
      return { authenticated: true, title: data.title, webUrl: data.webUrl, user: data.user, login: data.login, finalUrl: finalUrl };
    }
    return { authenticated: false, finalUrl: finalUrl, reason: 'REST status ' + (data && data.status) };
  } catch (e) {
    return { authenticated: false, finalUrl: finalUrl, reason: String(e && e.message ? e.message : e) };
  }
}

module.exports = { probeAuth };
