/**
 * Cierre de una llamada (real o simulada): resultado, costo, correo de confirmación o de seguimiento.
 * Idempotente: ElevenLabs puede reintentar el webhook.
 */
import { providers } from '../config.js';
import { gemini, modelFor } from '../lib/llm.js';
import { db, supabase } from '../lib/supabase.js';
import { dropState, getState, type ConversationState } from '../voice/state.js';
import { fallbackItemFromState, sendConfirmationEmail, sendRunEmail } from './email.js';

const BY_OFFER_TYPE: Record<string, string> = {
  FULL_PAYMENT: 'PAYMENT_COMMITMENT', REMINDER: 'PAYMENT_COMMITMENT', FEE_WAIVER: 'PAYMENT_COMMITMENT',
  INSTALLMENT_PLAN: 'PAYMENT_PLAN_AGREED', DATE_EXTENSION: 'DATE_EXTENSION_AGREED',
  PARTIAL_PAYMENT: 'PARTIAL_PAYMENT_AGREED', CALLBACK: 'CALLBACK_SCHEDULED',
};

function decideOutcome(state: ConversationState | null, answered: boolean): string {
  if (!answered) return 'NO_ANSWER';
  if (state?.commitment && (!state.outcome || state.outcome === 'FOLLOW_UP_REQUIRED')) {
    if (state.commitment.requiresApproval) return 'PENDING_APPROVAL';
    const type = state.context.offers.find((o) => o.code === state.commitment!.code)?.offer_type ?? '';
    return BY_OFFER_TYPE[type] ?? 'PAYMENT_COMMITMENT';
  }
  if (state?.outcome) return state.outcome;
  return state?.customerSpoke ? 'FOLLOW_UP_REQUIRED' : 'ABANDONED';
}

export async function finalizeConversation(conversationId: string, opts: {
  answered: boolean;
  durationSecs?: number | null;
  summary?: string | null;
  failureReason?: string | null;
  realCall: boolean;
  /** Cerrada a mano desde la web: no se manda correo de "intentamos comunicarnos". */
  manual?: boolean;
}): Promise<{ outcome: string; alreadyClosed: boolean }> {
  const row = await db.conversationRow(conversationId);
  if (!row) throw new Error(`CONVERSACION_NO_EXISTE: ${conversationId}`);
  if (row.status !== 'active') return { outcome: 'ALREADY_CLOSED', alreadyClosed: true };

  const state = await getState(conversationId).catch(() => null);
  await settle(state?.supervisor ?? null, 5000);

  const outcome = opts.failureReason && !opts.answered ? 'NO_ANSWER' : decideOutcome(state, opts.answered);
  // El resumen de ElevenLabs llega en inglés: se genera uno en español desde nuestra transcripción (el original queda en meta)
  const summary = opts.answered ? (await spanishSummary(conversationId, outcome, state).catch(() => null)) ?? opts.summary ?? null : opts.summary ?? null;
  await db.endConversation(conversationId, outcome, summary, {
    ...(opts.failureReason ? { reason: opts.failureReason } : {}),
    ...(opts.summary && opts.summary !== summary ? { provider_summary: opts.summary } : {}),
  });

  if (opts.realCall && opts.durationSecs) {
    await Promise.all([
      db.recordModelUsage(conversationId, 'voice.elevenlabs', { audio_in_seconds: opts.durationSecs }).catch(() => null),
      db.recordModelUsage(conversationId, 'telephony.twilio-sv-mobile', { audio_in_seconds: opts.durationSecs }).catch(() => null),
    ]);
  }

  if (state) {
    const policy = await db.activePolicy().catch(() => null);
    if (state.commitment && !state.whatsappHandoffCreated) {
      await sendConfirmationEmail(state);
    } else if (!opts.answered && !opts.manual && (policy?.email_fallback ?? true)) {
      const item = await fallbackItemFromState(state);
      if (item) await sendRunEmail(item, 'fallback');
    }
  }

  dropState(conversationId);
  console.log(`[finalize] ${conversationId} → ${outcome} (${opts.realCall ? providers.voice() : 'simulada'})`);
  return { outcome, alreadyClosed: false };
}

async function spanishSummary(conversationId: string, outcome: string, state: ConversationState | null): Promise<string | null> {
  const { data } = await supabase.from('messages').select('role,content').eq('conversation_id', conversationId)
    .in('role', ['agent', 'customer']).order('seq').limit(80);
  if (!data?.length) return null;
  const transcript = data.map((m) => `${m.role === 'agent' ? 'Agente' : 'Cliente'}: ${m.content}`).join('\n').slice(0, 9000);
  const model = await modelFor('supervisor');
  const res = await gemini.chat.completions.create({
    model: model.modelId, temperature: 0, max_tokens: 220,
    messages: [
      { role: 'system', content: 'Resume en ESPAÑOL, en 2 o 3 frases y en tercera persona, una llamada de cobranza preventiva de Bancoagrícola. Incluye: situación del cliente, lo acordado (fecha y monto solo si aparecen en la transcripción) y el resultado final. Sin inventar datos. Sin viñetas.' },
      { role: 'user', content: `Resultado registrado: ${outcome}${state?.commitment ? ` · compromiso ${state.commitment.receipt}` : ' · sin compromiso registrado'}\n\nTranscripción:\n${transcript}` },
    ],
  }, { timeout: 8000 });
  return res.choices[0]?.message?.content?.trim() || null;
}

async function settle(p: Promise<unknown> | null, ms: number): Promise<void> {
  if (!p) return;
  await Promise.race([p.catch(() => null), new Promise((r) => setTimeout(r, ms))]);
}
