/**
 * Cierre de una llamada (real o simulada): resultado, costo, correo de confirmación o de seguimiento.
 * Idempotente: ElevenLabs puede reintentar el webhook.
 */
import { providers } from '../config.js';
import { db } from '../lib/supabase.js';
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
}): Promise<{ outcome: string; alreadyClosed: boolean }> {
  const row = await db.conversationRow(conversationId);
  if (!row) throw new Error(`CONVERSACION_NO_EXISTE: ${conversationId}`);
  if (row.status !== 'active') return { outcome: 'ALREADY_CLOSED', alreadyClosed: true };

  const state = await getState(conversationId).catch(() => null);
  await settle(state?.supervisor ?? null, 5000);

  const outcome = opts.failureReason && !opts.answered ? 'NO_ANSWER' : decideOutcome(state, opts.answered);
  await db.endConversation(conversationId, outcome, opts.summary ?? null, opts.failureReason ? { reason: opts.failureReason } : {});

  if (opts.realCall && opts.durationSecs) {
    await Promise.all([
      db.recordModelUsage(conversationId, 'voice.elevenlabs', { audio_in_seconds: opts.durationSecs }).catch(() => null),
      db.recordModelUsage(conversationId, 'telephony.twilio-sv-mobile', { audio_in_seconds: opts.durationSecs }).catch(() => null),
    ]);
  }

  if (state) {
    const policy = await db.activePolicy().catch(() => null);
    if (state.commitment) {
      await sendConfirmationEmail(state);
    } else if (!opts.answered && (policy?.email_fallback ?? true)) {
      const item = await fallbackItemFromState(state);
      if (item) await sendRunEmail(item, 'fallback');
    }
  }

  dropState(conversationId);
  console.log(`[finalize] ${conversationId} → ${outcome} (${opts.realCall ? providers.voice() : 'simulada'})`);
  return { outcome, alreadyClosed: false };
}

async function settle(p: Promise<unknown> | null, ms: number): Promise<void> {
  if (!p) return;
  await Promise.race([p.catch(() => null), new Promise((r) => setTimeout(r, ms))]);
}
