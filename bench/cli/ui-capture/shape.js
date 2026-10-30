(() => { const enumish = s => /^[A-Z][A-Z0-9_]{2,}$/.test(s);
const sh = (v, d) => { if (Array.isArray(v)) return v.length ? [sh(v[0], d + 1), '…n=' + v.length] : [];
  if (v && typeof v === 'object') { if (d > 7) return '{..}'; const o = {}; for (const k of Object.keys(v)) o[k] = sh(v[k], d + 1); return o }
  if (typeof v === 'string') return enumish(v) ? 'enum:' + v : (/^-?\d+$/.test(v) ? 'int64-string' : (/^\d{4}-\d\d-\d\dT/.test(v) ? 'timestamp' : 'string'));
  return typeof v };
const out = {}; for (const k of Object.keys(window.__cap).sort()) if (!/GetPaymentMethod|ListMyAccounts|GetCurrentUser|ListCommunityKits|ListSandboxKits|ListHarnesses/.test(k)) out[k] = sh(window.__cap[k], 0);
return JSON.stringify(out, null, 1) })()
