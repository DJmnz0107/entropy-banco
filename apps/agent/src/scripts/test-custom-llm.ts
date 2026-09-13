/**
 * Prueba el endpoint Custom LLM EXACTAMENTE como lo llama ElevenLabs (HTTP + SSE), contra el servidor local.
 *   npx tsx apps/agent/src/scripts/test-custom-llm.ts [DEMO-003] [http://localhost:3000]
 */
import { config } from '../config.js';
import { db, rpc, supabase } from '../lib/supabase.js';

const code = process.argv[2] ?? 'DEMO-003';
const base = process.argv[3] ?? `http://localhost:${config.port}`;
const customer = await db.customerByCode(code);
if (!customer) throw new Error(`Cliente ${code} no existe`);
const { conversation_id: conv } = await rpc<{ conversation_id: string }>('start_conversation', {
  p_customer_id: customer.id, p_channel: 'voice', p_direction: 'inbound', p_external_id: 'test-custom-llm',
});

async function turn(messages: Array<{ role: string; content: string }>) {
  const t0 = Date.now();
  const res = await fetch(`${base}${process.env.LLM_PATH ?? '/v1/chat/completions'}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(config.customLlmSecret ? { Authorization: `Bearer ${config.customLlmSecret}` } : {}) },
    body: JSON.stringify({
      model: 'banca-inteligente', stream: true,
      messages: [{ role: 'system', content: `CONVERSATION_ID=${conv}` }, ...messages],
      tools: [{ type: 'function', function: { name: 'end_call', description: 'Termina la llamada', parameters: { type: 'object', properties: {} } } }],
    }),
  });
  const raw = await res.text();
  let text = '';
  let endCall = false;
  let firstChunkMs = -1;
  for (const line of raw.split('\n')) {
    if (!line.startsWith('data: ') || line === 'data: [DONE]') continue;
    const chunk = JSON.parse(line.slice(6)) as { choices: Array<{ delta: { content?: string; tool_calls?: Array<{ function: { name: string } }> }; finish_reason: string | null }> };
    const delta = chunk.choices[0]?.delta;
    if (delta?.content) { text += delta.content; if (firstChunkMs < 0) firstChunkMs = Date.now() - t0; }
    if (delta?.tool_calls?.some((t) => t.function.name === 'end_call')) endCall = true;
  }
  return { status: res.status, text, endCall, ms: Date.now() - t0, sse: raw.trim().endsWith('data: [DONE]') };
}

const history = [
  { role: 'assistant', content: `Buenas tardes. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con ${customer.full_name}?` },
  { role: 'user', content: 'No, él no está, soy la esposa.' },
];
const r = await turn(history);
console.log(`HTTP ${r.status} · SSE válido: ${r.sse} · ${r.ms} ms\n🤖 ${r.text}\nend_call: ${r.endCall}`);

await new Promise((resolve) => setTimeout(resolve, 5000));
const [{ data: msgs }, { data: evals }] = await Promise.all([
  supabase.from('messages').select('seq, role, content').eq('conversation_id', conv).order('seq'),
  supabase.from('turn_evaluations').select('from_stage, to_stage, decision, rule_label').eq('conversation_id', conv).order('seq'),
]);
console.log('── mensajes', msgs?.map((m) => `${m.seq}.${m.role}: ${(m.content as string).slice(0, 90)}`));
console.log('── evaluación', evals);
await db.endConversation(conv, 'WRONG_PERSON', 'Prueba técnica del endpoint Custom LLM.').catch(() => null);
process.exit(0);
