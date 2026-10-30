(async () => { const srcs = [...new Set(performance.getEntriesByType('resource').map(e => e.name).filter(n => /\.m?js(\?|$)/.test(n) && n.includes('agentic-platform')))];
const out = {}; let files = 0;
for (const s of srcs) { let t; try { t = await (await fetch(s)).text() } catch (e) { continue }
  for (const m of t.matchAll(/["'`](Ch[A-Za-z0-9+/=]{100,})["'`]/g)) { let b; try { b = atob(m[1]) } catch (e) { continue }
    if (!/\.v1/.test(b)) continue; files++;
    const pkg = (b.match(/\x12[\x01-\x7f]((?:platform|auth)\.v1)/) || [])[1] || '?';
    const re = /\n[\x01-\x7f]([A-Z][A-Za-z0-9]+)\x12[\x01-\x7f]\.[a-z.0-9]+\.([A-Za-z0-9]+)\x1a[\x01-\x7f]\.[a-z.0-9]+\.([A-Za-z0-9]+)([\s\S]{0,6})/g;
    for (const x of b.matchAll(re)) { const ss = x[4].includes('0\x01') || x[4].includes('(\x01') ? ' [stream]' : '';
      (out[pkg] = out[pkg] || new Set()).add(x[1] + '(' + x[2] + ') -> ' + x[3] + ss) }
    for (const x of b.matchAll(/2[\x01-\x7f\x80-\xff]{1,2}\n[\x01-\x7f]([A-Z][A-Za-z]+Service)/g)) (out[pkg + ' services'] = out[pkg + ' services'] || new Set()).add(x[1]) } }
const r = { files }; for (const k in out) r[k] = [...out[k]].sort(); return JSON.stringify(r, null, 1) })()
