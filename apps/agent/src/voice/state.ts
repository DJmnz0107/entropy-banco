/**
 * Estado en memoria por conversación. Si el servidor se reinicia a mitad de llamada,
 * se reconstruye desde Supabase (la BD es la fuente de verdad).
 */
import { db, type ConversationContext, type Json, type Stage } from '../lib/supabase.js';

export interface ConversationState {
  conversationId: string;
  customerId: string;
  interventionId: string | null;
  channel: string;
  simulated: boolean;
  context: ConversationContext;
  nextBest: Json | null;
  stage: string;
  pace: 'slow' | 'normal' | 'fast';
  pendingControl: string | null;
  validated: Record<string, Json>;          // oferta → parámetros normalizados por la BD
  lastPresentedOffer: string | null;
  commitment: { receipt: string; code: string; status: string; requiresApproval: boolean; generatesPaymentLink: boolean } | null;
  endCall: boolean;
  outcome: string | null;
  lastAgentText: string | null;
  lastAgentMessageId: string | null;
  customerSpoke: boolean;
  confirmationEmailSent: boolean;
  supervisor: Promise<void> | null;         // evaluación del turno anterior (asíncrona)
  customerLogged: Promise<{ message_id: string } | null> | null;
  startedAt: number;
  turns: number;
}

const states = new Map<string, ConversationState>();

export function stageInfo(state: ConversationState, key = state.stage): Stage | undefined {
  return state.context.playbook.stages.find((s) => s.key === key);
}

export async function getState(conversationId: string): Promise<ConversationState> {
  const cached = states.get(conversationId);
  if (cached) return cached;

  const row = await db.conversationRow(conversationId);
  if (!row) throw new Error(`CONVERSACION_NO_EXISTE: ${conversationId}`);
  const [context, intervention, commitment] = await Promise.all([
    db.context(row.customer_id),
    row.intervention_id ? db.interventionById(row.intervention_id) : Promise.resolve(null),
    row.commitment_id ? db.commitment(row.commitment_id) : Promise.resolve(null),
  ]);

  const state: ConversationState = {
    conversationId,
    customerId: row.customer_id,
    interventionId: row.intervention_id,
    channel: row.channel,
    simulated: row.is_synthetic,
    context,
    nextBest: intervention?.next_best ?? null,
    stage: row.current_stage,
    pace: 'normal',
    pendingControl: null,
    validated: {},
    lastPresentedOffer: null,
    commitment: commitment ? {
      receipt: commitment.receipt_code, code: commitment.offer_code, status: commitment.status,
      requiresApproval: commitment.requires_approval, generatesPaymentLink: false,
    } : null,
    endCall: false,
    outcome: null,
    lastAgentText: null,
    lastAgentMessageId: null,
    customerSpoke: row.turn_count > 0,
    confirmationEmailSent: false,
    supervisor: null,
    customerLogged: null,
    startedAt: new Date(row.started_at).getTime(),
    turns: 0,
  };
  states.set(conversationId, state);
  return state;
}

export function dropState(conversationId: string): void {
  states.delete(conversationId);
}

export function activeStates(): ConversationState[] {
  return [...states.values()];
}
