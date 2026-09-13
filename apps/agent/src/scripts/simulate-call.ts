/**
 * Llamada simulada desde la terminal (usa Supabase y Gemini reales, sin ElevenLabs).
 *   npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-001 ESC-C
 *   npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-002          (cliente interpretado por Gemini)
 */
import { db, supabase } from '../lib/supabase.js';
import { loadScenario, runSimulatedCall } from '../channels/simulated-call.js';

const [code = 'DEMO-001', scenarioKey] = process.argv.slice(2);
const customer = await db.customerByCode(code);
if (!customer) throw new Error(`Cliente ${code} no existe`);
const intervention = await db.interventionForCustomer(customer.id);
const scenario = scenarioKey ? await loadScenario(scenarioKey) : undefined;

console.log(`\n📞 Llamada simulada a ${customer.full_name}${scenario ? ` · ${scenario.key}: ${scenario.description ?? ''}` : ''}\n`);
const t0 = Date.now();
const result = await runSimulatedCall(customer.id, intervention?.id ?? null, scenario, { pacingMs: 0 });
for (const m of result.transcript) console.log(`${m.role === 'user' ? '👤' : '🤖'} ${m.content}`);

const [{ data: evals }, { data: msgs }, { data: conv }, { data: events }] = await Promise.all([
  supabase.from('turn_evaluations').select('seq, from_stage, to_stage, decision, intent, sentiment, rule_label').eq('conversation_id', result.conversationId).order('seq'),
  supabase.from('messages').select('role, latency_ms, interrupted').eq('conversation_id', result.conversationId).eq('role', 'agent'),
  supabase.from('conversations').select('outcome, current_stage, commitment_id, interruption_count, refusal_count, escalated').eq('id', result.conversationId).single(),
  supabase.from('conversation_events').select('event_type, severity').eq('conversation_id', result.conversationId).order('created_at'),
]);
console.log('\n── Etapas');
for (const e of evals ?? []) console.log(`  ${e.seq}. ${e.from_stage} → ${e.to_stage} (${e.decision}) · ${e.intent ?? '-'} · ${e.sentiment ?? '-'} · ${e.rule_label ?? ''}`);
const lat = (msgs ?? []).map((m) => m.latency_ms as number).filter((n) => n >= 0).sort((a, b) => a - b);
console.log('\n── Resultado', conv);
console.log('── Eventos', (events ?? []).map((e) => e.event_type).join(' · '));
console.log(`── Latencia primer token: p50 ${lat[Math.floor(lat.length / 2)] ?? '-'} ms · máx ${lat.at(-1) ?? '-'} ms · total ${(Date.now() - t0) / 1000}s`);
console.log(`── Conversación: ${result.conversationId}\n`);
process.exit(0);
