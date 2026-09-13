/**
 * Llamada simulada desde la terminal (usa Supabase y Gemini reales, sin ElevenLabs).
 *   npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-001 ESC-C
 *   npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-002          (cliente interpretado por Gemini)
 */
import { db, supabase } from '../lib/supabase.js';
import { extractDates, unvalidatedDate } from '../voice/guardrails.js';
import { todaySv } from '../voice/prompt.js';
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

// Criterios de aceptación del escenario (docs/REGLAS-AGENTE-VOZ.md §6)
const exp = scenario?.expect;
if (!exp) process.exit(0);
const { data: all } = await supabase.from('messages').select('role, content').eq('conversation_id', result.conversationId);
const agentText = (all ?? []).filter((m) => m.role === 'agent').map((m) => String(m.content)).join(' ').toLowerCase();
const toolCalls = (all ?? []).filter((m) => m.role === 'tool').map((m) => String(m.content));
const checks: Array<[string, boolean]> = [];
if (exp.outcome_in) checks.push([`resultado ∈ ${exp.outcome_in.join('|')} (fue ${conv?.outcome})`, exp.outcome_in.includes(String(conv?.outcome))]);
if (exp.commitment !== undefined) checks.push([`compromiso registrado = ${exp.commitment}`, Boolean(conv?.commitment_id) === exp.commitment]);
for (const stage of exp.must_reach_stages ?? []) checks.push([`pasa por ${stage}`, (evals ?? []).some((e) => e.to_stage === stage || e.from_stage === stage)]);
for (const phrase of exp.must_not_say ?? []) checks.push([`no dice "${phrase}"`, !agentText.includes(phrase.toLowerCase())]);
for (const ev of exp.must_have_events ?? []) checks.push([`evento ${ev}`, (events ?? []).some((e) => e.event_type === ev)]);
if (exp.max_same_offer_validations !== undefined) {
  const counts = new Map<string, number>();
  for (const t of toolCalls.filter((t) => t.startsWith('validar_oferta('))) {
    const key = t.split(' → ')[0];
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const worst = Math.max(0, ...counts.values());
  checks.push([`misma validación ≤ ${exp.max_same_offer_validations} (máx ${worst})`, worst <= exp.max_same_offer_validations]);
}
// Toda fecha afirmada por el agente debe venir del vencimiento, de hoy o de lo que devolvieron las herramientas
{
  const ctx = await db.context(customer.id);
  const allowed = new Set(extractDates([ctx.loan?.next_due_date_text ?? '', todaySv(), ...toolCalls].join(' . ')
    .replace(/(\d{4})-(\d{2})-(\d{2})/g, (_, _y, m, d) => `${Number(d)} de ${['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'][Number(m) - 1]}`)));
  const bad = (all ?? []).filter((m) => m.role === 'agent').flatMap((m) => String(m.content).split(/(?<=[.?!])\s+/)).filter((sentence) => unvalidatedDate(sentence, allowed));
  checks.push([`no afirma fechas sin validar${bad.length ? `: "${bad[0].slice(0, 80)}"` : ''}`, bad.length === 0]);
}
for (const needle of exp.db_must_not_contain ?? []) {
  checks.push([`BD no guarda "${needle}"`, !(all ?? []).some((m) => String(m.content).includes(needle))]);
}
console.log('── Criterios');
for (const [label, ok] of checks) console.log(`  ${ok ? '✅' : '❌'} ${label}`);
const failed = checks.filter(([, ok]) => !ok).length;
console.log(failed ? `\n${failed} criterio(s) fallaron` : '\nEscenario OK');
process.exit(failed ? 1 : 0);
