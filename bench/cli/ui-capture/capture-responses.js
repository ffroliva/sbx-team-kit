(() => { window.__cap = {}; const keep = (u, b) => { if (u.includes('/api/') && !u.includes('AuthService')) window.__cap[u.split('/api/')[1].split('?')[0]] = b };
for (const m of ['json', 'text', 'arrayBuffer']) { const o = Response.prototype[m];
  Response.prototype[m] = async function () { const u = this.url; const v = await o.call(this);
    try { if (m === 'json') keep(u, v); else if (m === 'text') keep(u, JSON.parse(v));
          else keep(u, JSON.parse(new TextDecoder().decode(v))) } catch (e) {} return v } }
return 'patched' })()
