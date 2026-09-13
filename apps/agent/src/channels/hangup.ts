/**
 * "Colgar" desde la web: cierra una conversación en curso (o atascada) sin dejarla abierta.
 * Simulada → el bucle deja de generar turnos. Real (ElevenLabs) → el siguiente turno del Custom LLM se despide y llama end_call.
 * El cierre en la BD es inmediato e idempotente (finalizeConversation / end_conversation).
 */
import { db } from '../lib/supabase.js';
import { getState } from '../voice/state.js';
import { finalizeConversation } from './finalize.js';

export async function hangupConversation(conversationId: string, requestedBy: string): Promise<{ outcome: string; alreadyClosed: boolean }> {
  const row = await db.conversationRow(conversationId);
  if (!row) throw new Error(`CONVERSACION_NO_EXISTE: ${conversationId}`);
  if (row.status !== 'active') return { outcome: 'ALREADY_CLOSED', alreadyClosed: true };

  // Marca el estado ANTES de cerrar: si hay un turno en curso, no arranca otro.
  const state = await getState(conversationId).catch(() => null);
  if (state) state.hangupRequested = true;
  await db.logEvent(conversationId, 'manual_hangup', { requested_by: requestedBy, channel: row.channel, simulated: row.is_synthetic }, 'warning');

  return finalizeConversation(conversationId, {
    answered: state?.customerSpoke ?? row.turn_count > 0,
    realCall: !row.is_synthetic,
    manual: true,
    summary: 'Conversación finalizada manualmente desde el panel.',
  });
}
