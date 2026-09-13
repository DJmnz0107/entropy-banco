// Corre los flujos end-to-end y falla (exit 1) si alguna aserción no pasa.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
let total = 0, failed = false;
for (const suite of ['flow.sql', 'prevention.sql', 'bank.sql', 'whatsapp_handoff.sql']) {
  const out = execFileSync('node', [path.join(here, 'run.mjs'), path.join(here, suite)], { encoding: 'utf8', maxBuffer: 1e8 });
  const fails = (out.match(/│ '❌' │/g) || []).length;
  const passes = (out.match(/│ '✅' │/g) || []).length;
  const sqlErrors = out.split('\n').filter(l => l.startsWith('❌'));
  total += passes;
  if (sqlErrors.length || fails || passes === 0) {
    console.log(out.slice(out.indexOf('── RESULTADOS')));
    console.error(`\n${suite} FALLÓ: ${fails} aserciones, errores SQL: ${sqlErrors.join(' | ')}`);
    failed = true;
  } else {
    console.log(`✅ ${suite}: ${passes} aserciones`);
  }
}
if (failed) process.exit(1);
console.log(`\nOK: ${total} aserciones pasaron`);
