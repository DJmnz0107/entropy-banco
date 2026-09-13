/**
 * Borra conversaciones SIMULADAS (is_synthetic = true) creadas desde una fecha, con sus compromisos, links,
 * handoffs y escalaciones. Nunca toca conversaciones reales ni el historial del seed (anterior a --since).
 *   npx tsx apps/agent/src/scripts/cleanup-simulations.ts 2026-09-13T06:10:00Z [--dry]
 */
import { supabase } from '../lib/supabase.js';

const since = process.argv[2];
const dry = process.argv.includes('--dry');
if (!since || Number.isNaN(Date.parse(since))) throw new Error('Uso: cleanup-simulations.ts <ISO desde> [--dry]');

const { data: convs, error } = await supabase.from('conversations').select('id, customer_id, outcome, started_at')
  .eq('is_synthetic', true).gte('started_at', since);
if (error) throw error;
const ids = (convs ?? []).map((c) => c.id);
console.log(`${ids.length} conversaciones simuladas desde ${since}`);
for (const c of convs ?? []) console.log(`  ${c.started_at} · cliente …${c.customer_id.slice(-3)} · ${c.outcome}`);
if (!ids.length || dry) process.exit(0);

const { data: commits } = await supabase.from('commitments').select('id').in('conversation_id', ids);
const commitIds = (commits ?? []).map((c) => c.id);
const steps: Array<[string, PromiseLike<{ error: { message: string } | null }>]> = [
  ['payment_links (conversación)', supabase.from('payment_links').delete().in('conversation_id', ids)],
  ...(commitIds.length ? [['payment_links (compromiso)', supabase.from('payment_links').delete().in('commitment_id', commitIds)] as [string, PromiseLike<{ error: { message: string } | null }>]] : []),
  ['handoffs', supabase.from('handoffs').delete().in('from_conversation_id', ids)],
  ['escalations', supabase.from('escalations').delete().in('conversation_id', ids)],
  ['education_deliveries', supabase.from('education_deliveries').delete().in('conversation_id', ids)],
];
for (const [name, q] of steps) { const { error: e } = await q; console.log(`  ${e ? '❌' : '✅'} ${name}${e ? `: ${e.message}` : ''}`); }
if (commitIds.length) { const { error: e } = await supabase.from('commitments').delete().in('id', commitIds); console.log(`  ${e ? '❌' : '✅'} commitments (${commitIds.length})${e ? `: ${e.message}` : ''}`); }
const { error: e2 } = await supabase.from('conversations').delete().in('id', ids);
console.log(`  ${e2 ? '❌' : '✅'} conversations (${ids.length})${e2 ? `: ${e2.message}` : ''}`);
process.exit(e2 ? 1 : 0);
