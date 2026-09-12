import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
const db = new PGlite();
// Stubs de lo que Supabase ya trae
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin;
  create publication supabase_realtime;
`);
const files = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
for (const f of files) {
  try { await db.exec(fs.readFileSync(path.join(dir, f), 'utf8')); console.log('✅', f); }
  catch (e) { console.log('❌', f, '\n   ', e.message, e.position ? `(pos ${e.position})` : '', e.where || ''); process.exit(1); }
}
const extra = process.argv[2];
if (extra) {
  for (const q of fs.readFileSync(extra, 'utf8').split(/^-- @@\s*/m).filter(Boolean)) {
    const [title, ...rest] = q.split('\n'); const sql = rest.join('\n').trim(); if (!sql) continue;
    try {
      const t0 = Date.now(); const r = await db.query(sql); const ms = Date.now() - t0;
      console.log(`\n── ${title.trim()} (${ms}ms)`);
      if (r.rows.length) console.table(r.rows.slice(0, 40).map(row => Object.fromEntries(Object.entries(row).map(([k,v]) => [k, typeof v === 'object' && v !== null ? JSON.stringify(v).slice(0, 140) : v]))));
    } catch (e) { console.log(`\n❌ ${title.trim()}\n   ${e.message}`, e.where || ''); }
  }
}
