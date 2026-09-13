/**
 * Ejecuta una corrida: C–E → llamada (ElevenLabs o simulada), A–B → correo,
 * C–E que no se pueden llamar → correo de seguimiento. La política vive en la BD.
 */
import { config, providers } from '../config.js';
import { outboundCall } from '../lib/elevenlabs.js';
import { db, type RunIntervention } from '../lib/supabase.js';
import { getState } from '../voice/state.js';
import { sendRunEmail } from './email.js';
import { finalizeConversation } from './finalize.js';
import { runSimulatedCall } from './simulated-call.js';

export interface DispatchPlan {
  run_id: string;
  voice_provider: 'elevenlabs' | 'simulated';
  email_provider: 'resend' | 'simulated';
  real_calls: number;
  simulated_calls: number;
  reminder_emails: number;
  fallback_emails: number;
  real_emails: number;
  human: number;
  notes: string[];
}

const running = new Set<string>();

function isRealEmail(item: RunIntervention): boolean {
  return providers.email() === 'resend' && item.contact_enabled && !!item.email && !/\.test$|\.invalid$/i.test(item.email);
}

/** Llamada real a un cliente con ElevenLabs. Si falla, cierra como no contestada y manda correo. */
export async function startRealCall(item: Pick<RunIntervention, 'customer_id' | 'intervention_id' | 'phone_e164' | 'first_name' | 'full_name' | 'grade' | 'amount_due_text' | 'due_date_text'>): Promise<{ conversationId: string; elevenlabsConversationId: string | null }> {
  if (!item.phone_e164) throw new Error('El cliente no tiene teléfono');
  const start = await db.startConversation(item.customer_id, 'voice', item.intervention_id || null);
  const conversationId = start.conversation_id;
  await getState(conversationId);   // precarga el contexto: el primer turno responde más rápido
  try {
    const res = await outboundCall(item.phone_e164, {
      conversation_id: conversationId,
      nombre: item.first_name,
      nombre_completo: item.full_name,
      grado: item.grade ?? '',
      monto: item.amount_due_text ?? '',
      fecha: item.due_date_text ?? '',
    });
    if (res.conversationId) await db.setExternalId(conversationId, res.conversationId);
    return { conversationId, elevenlabsConversationId: res.conversationId };
  } catch (err) {
    await finalizeConversation(conversationId, { answered: false, realCall: true, failureReason: (err as Error).message });
    throw err;
  }
}

export async function planAndDispatch(runId: string): Promise<DispatchPlan> {
  const run = await db.getRun(runId);
  const policy = run.policy;
  const voiceMode = providers.voice();
  const items = run.interventions;

  const voice = items.filter((i) => i.channel === 'voice');
  const email = items.filter((i) => i.channel === 'email');
  const human = items.filter((i) => i.channel === 'human');

  const realCalls: RunIntervention[] = [];
  const simulatedCalls: RunIntervention[] = [];
  const fallback: RunIntervention[] = [];
  for (const item of voice) {
    if (voiceMode === 'elevenlabs' && item.contact_enabled && item.phone_e164 && realCalls.length < policy.max_calls_per_run) realCalls.push(item);
    else if (voiceMode === 'simulated' && config.simulateCallsWhenNoVoiceProvider && simulatedCalls.length < policy.max_simulated_calls_per_run) simulatedCalls.push(item);
    else if (policy.email_fallback) fallback.push(item);
  }

  const notes: string[] = [];
  if (voiceMode === 'simulated') notes.push('Sin ElevenLabs configurado: las llamadas se simulan con Gemini.');
  if (providers.email() === 'simulated') notes.push('Sin RESEND_API_KEY: los correos se registran pero no se envían.');
  if (voiceMode === 'elevenlabs' && !voice.some((i) => i.contact_enabled)) notes.push('Ningún cliente de C–E tiene contacto habilitado: nadie recibe llamada real (usa set_demo_contact).');

  const plan: DispatchPlan = {
    run_id: runId, voice_provider: voiceMode, email_provider: providers.email(),
    real_calls: realCalls.length, simulated_calls: simulatedCalls.length,
    reminder_emails: email.length, fallback_emails: fallback.length,
    real_emails: [...email, ...fallback].filter(isRealEmail).length,
    human: human.length, notes,
  };

  if (running.has(runId)) {
    plan.notes.push('Esta corrida ya se está despachando.');
    return plan;
  }
  running.add(runId);
  await db.markRunDispatched(runId, { ...plan, status: 'in_progress' });

  // Ejecución en segundo plano: la web ve el avance por Realtime
  void (async () => {
    const results = { calls_started: 0, calls_failed: 0, simulated_done: 0, emails_sent: 0, emails_failed: 0, errors: [] as string[] };
    try {
      for (const item of realCalls) {
        try { await startRealCall(item); results.calls_started++; }
        catch (err) { results.calls_failed++; results.errors.push(`${item.customer_code}: ${(err as Error).message}`); }
        await new Promise((r) => setTimeout(r, 2500));
      }
      for (const item of email) {
        const r = await sendRunEmail(item, 'reminder');
        if (r.error) { results.emails_failed++; results.errors.push(`${item.customer_code}: ${r.error}`); } else results.emails_sent++;
      }
      for (const item of fallback) {
        const r = await sendRunEmail(item, 'fallback');
        if (r.error) { results.emails_failed++; results.errors.push(`${item.customer_code}: ${r.error}`); } else results.emails_sent++;
      }
      for (const item of simulatedCalls) {
        try { await runSimulatedCall(item.customer_id, item.intervention_id); results.simulated_done++; }
        catch (err) { results.errors.push(`${item.customer_code} (simulada): ${(err as Error).message}`); }
      }
    } finally {
      running.delete(runId);
      await db.markRunDispatched(runId, { ...plan, status: 'completed', results }).catch(() => null);
      console.log(`[dispatch] corrida ${runId} terminada`, results);
    }
  })();

  return plan;
}
