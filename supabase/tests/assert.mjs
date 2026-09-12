// Corre el flujo end-to-end y falla (exit 1) si alguna aserción no pasa.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const out = execFileSync('node', [path.join(here, 'run.mjs'), path.join(here, 'flow.sql')], { encoding: 'utf8', maxBuffer: 1e8 });
const fails = (out.match(/│ '❌' │/g) || []).length;
const passes = (out.match(/│ '✅' │/g) || []).length;
const sqlErrors = out.split('\n').filter(l => l.startsWith('❌'));
console.log(out.slice(out.indexOf('── RESULTADOS')));
if (sqlErrors.length || fails || passes === 0) { console.error(`\nFALLÓ: ${fails} aserciones, errores SQL: ${sqlErrors.join(' | ')}`); process.exit(1); }
console.log(`\nOK: ${passes} aserciones pasaron`);
