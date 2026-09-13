/**
 * Reproduce lo que hace ElevenLabs cuando el cliente sigue hablando: cancela el request en curso y manda
 * otro con la transcripción más larga. Verifica que no se dupliquen mensajes ni se marquen interrupciones falsas.
 *   npx tsx apps/agent/src/scripts/test-cancel-turns.ts [DEMO-002]
 */
import { config } from '../config.js';
import { db, supabase } from '../lib/supabase.js';

const code = process.argv[2] ?? 'DEMO-002';
const base = `http://localhost:${config.port}`;
const customer = await db.customerByCode(code);
if (!customer) throw new Error(`Cliente ${code} no existe`);
const { conversation_id: conv } = await db.startSimulated(customer.id, 'voice', null);

async function turn(history: Array<{ role: string; content: string }>, abortAfterMs?: number): Promise<string> {
  const ctrl = new AbortController();
  if (abortAfterMs) setTimeout(() => ctrl.abort(), abortAfterMs);
  try {
    const res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', signal: ctrl.signal,
      headers: { 'Content-Type': 'application/json', ...(config.customLlmSecret ? { Authorization: `Bearer ${config.customLlmSecret}` } : {}) },
      body: JSON.stringify({ stream: true, messages: [{ role: 'system', content: `CONVERSATION_ID=${conv}` }, ...history] }),
    });
    const raw = await res.text();
    return raw.split('\n').filter((l) => l.startsWith('data: {')).map((l) => JSON.parse(l.slice(6)).choices[0]?.delta?.content ?? '').join('');
  } catch { return '(cancelado)'; }
}

const first = `Buenos días, ${customer.first_name}. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con ${customer.full_name}?`;
const a1 = await turn([{ role: 'assistant', content: first }, { role: 'user', content: 'Sí.' }]);
console.log('R1 →', a1);
console.log('R2 →', await turn([{ role: 'assistant', content: first }, { role: 'user', content: 'Sí.' }, { role: 'assistant', content: a1 }, { role: 'user', content: 'Sí, mire,' }], 250));
await new Promise((r) => setTimeout(r, 2500));   // el request cancelado sigue vivo en el servidor un momento
const a3 = await turn([{ role: 'assistant', content: first }, { role: 'user', content: 'Sí.' }, { role: 'assistant', content: a1 }, { role: 'user', content: 'Sí, mire, me pagan hasta el 16.' }]);
console.log('R3 →', a3);
await new Promise((r) => setTimeout(r, 3000));

const { data: msgs } = await supabase.from('messages').select('role,content').eq('conversation_id', conv).order('seq');
const { data: evs } = await supabase.from('conversation_events').select('event_type').eq('conversation_id', conv).like('event_type', 'interruption%');
console.log('\nMensajes:'); for (const m of msgs ?? []) console.log(`  ${m.role}: ${String(m.content).slice(0, 90)}`);
const customerRows = (msgs ?? []).filter((m) => m.role === 'customer').length;
const agentRows = (msgs ?? []).filter((m) => m.role === 'agent').length;
console.log(`\ncliente=${customerRows} (esperado 2) · agente=${agentRows} (esperado 2) · interrupciones=${evs?.length ?? 0} (esperado 0)`);
await db.endConversation(conv, 'FOLLOW_UP_REQUIRED', 'Prueba de turnos cancelados').catch(() => null);
process.exit(customerRows === 2 && agentRows === 2 && !evs?.length ? 0 : 1);
