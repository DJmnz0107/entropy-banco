/** Prueba del motor de turnos contra Supabase + Gemini reales (conversación entrante de prueba). */
import { db, rpc, supabase } from '../lib/supabase.js';
import { getState } from '../voice/state.js';
import { runAgentTurn, type HistoryMessage } from '../voice/turn.js';

const code = process.argv[2] ?? 'DEMO-001';
const lines = [
  '¿Aló?',
  'Sí, con él habla.',
  'Fíjese que este mes ando complicado, me atrasaron el pago en el trabajo. Completa no la alcanzo.',
  'La mitad sí podría pagarla, y lo demás el otro viernes.',
  'Sí, de acuerdo, regístrelo así.',
  'No, eso sería todo, gracias.',
];
const customer = await db.customerByCode(code);
if (!customer) throw new Error('cliente no existe');
const start = await rpc<{ conversation_id: string }>('start_conversation', { p_customer_id: customer.id, p_channel: 'voice', p_direction: 'inbound', p_external_id: 'test-claude' });
const conv = start.conversation_id;
const state = await getState(conv);
const history: HistoryMessage[] = [];
for (const line of lines) {
  history.push({ role: 'user', content: line });
  const r = await runAgentTurn({ state, history, voice: true });
  history.push({ role: 'assistant', content: r.text });
  console.log(`👤 ${line}\n🤖 ${r.text}   [ttfb ${r.ttfbMs} ms · total ${r.totalMs} ms · etapa ${state.stage}${r.endCall ? ' · END' : ''}]`);
  if (r.endCall) break;
}
await state.supervisor;
const { data: tools } = await supabase.from('messages').select('content').eq('conversation_id', conv).eq('role', 'tool').order('seq');
const { data: evals } = await supabase.from('turn_evaluations').select('from_stage,to_stage,decision,rule_label').eq('conversation_id', conv).order('seq');
const { data: row } = await supabase.from('conversations').select('commitment_id,current_stage').eq('id', conv).single();
console.log('\n── tools'); (tools ?? []).forEach((t) => console.log('  ', (t.content as string).slice(0, 220)));
console.log('── etapas'); (evals ?? []).forEach((e) => console.log(`   ${e.from_stage} → ${e.to_stage} (${e.decision}) ${e.rule_label ?? ''}`));
console.log('── conversación', conv, row);
await db.endConversation(conv, row?.commitment_id ? 'PARTIAL_PAYMENT_AGREED' : 'FOLLOW_UP_REQUIRED', 'Prueba técnica del motor de turnos (Claude).').catch((e) => console.log('end:', e.message));
process.exit(0);
