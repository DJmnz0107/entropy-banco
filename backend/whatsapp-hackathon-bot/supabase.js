import { createClient } from '@supabase/supabase-js';

// service_role: las funciones RPC del motor (start_conversation, log_message, evaluate_turn...)
// están bloqueadas para "anon" a propósito (ver 0900_security_realtime.sql). Este backend
// corre en servidor, nunca en el navegador, así que puede usar la llave secreta.
const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

// Reintenta fallas transitorias de red/gateway hacia Supabase (timeouts,
// 502/503/504) — mismo criterio que en gemini.js. Errores de negocio
// (violación de constraint, excepción de la función SQL, etc.) no se
// reintentan porque van a volver a fallar igual.
async function withRetry(fn, { retries = 2, delayMs = 800 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      const transient = /timeout|gateway|fetch failed|ECONNRESET|network/i.test(String(err?.message ?? err));
      if (!transient || attempt === retries) throw err;
      console.warn(`Llamada a Supabase falló (intento ${attempt + 1}/${retries + 1}), reintentando...`, err?.message ?? err);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}

async function rpc(fn, params = {}) {
  return withRetry(async () => {
    const { data, error } = await supabase.rpc(fn, params);
    if (error) throw error;
    return data;
  });
}

export async function findCustomerByPhone(phone) {
  return rpc('find_customer_by_phone', { p_phone: phone });
}

export async function getActiveConversation(customerId, channel) {
  return withRetry(async () => {
    const { data, error } = await supabase
      .from('conversations')
      .select('id, current_stage, context_snapshot, allowed_offers, terms_interrupted')
      .eq('customer_id', customerId)
      .eq('channel', channel)
      .eq('status', 'active')
      .order('started_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    return data;
  });
}

// Cuando el cliente escribe justo después de que su conversación anterior
// terminó (ej. quedó en REAGENDADO/CIERRE), no hay conversación activa —
// pero tratarlo como un cliente totalmente nuevo hace que el bot se vuelva
// a presentar y pida identidad de nuevo, lo cual suena roto. Esto permite
// detectar ese caso y avisarle al composer que no reinicie el guion.
export async function getRecentlyEndedConversation(customerId, channel, withinMinutes = 180) {
  return withRetry(async () => {
    const since = new Date(Date.now() - withinMinutes * 60 * 1000).toISOString();
    const { data, error } = await supabase
      .from('conversations')
      .select('id, outcome, ended_at')
      .eq('customer_id', customerId)
      .eq('channel', channel)
      .neq('status', 'active')
      .gte('ended_at', since)
      .order('ended_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    return data;
  });
}

export async function startConversation(customerId, channel, direction = 'inbound', parentConversationId = null) {
  return rpc('start_conversation', {
    p_customer_id: customerId, p_channel: channel, p_direction: direction,
    p_parent_conversation_id: parentConversationId,
  });
}

// Handoff de voz → WhatsApp (docs/TAREA-CLAUDE-HANDOFF-VOZ-WHATSAPP.md): el cliente escribe
// "CONTINUAR" (o cualquier mensaje) y esto revisa si tiene un traspaso pendiente esperándolo.
export async function getPendingWhatsAppHandoff(customerId) {
  return withRetry(async () => {
    const { data, error } = await supabase
      .from('handoffs')
      .select('id, from_conversation_id, to_channel, action, payload, context_summary, status, scheduled_for')
      .eq('customer_id', customerId)
      .eq('to_channel', 'whatsapp')
      .eq('status', 'pending')
      .lte('scheduled_for', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    return data;
  });
}

export async function claimHandoff(handoffId) {
  return rpc('claim_handoff', { p_handoff_id: handoffId });
}

export async function completeHandoff(handoffId, toConversationId, status, error = null) {
  return rpc('complete_handoff', {
    p_handoff_id: handoffId, p_to_conversation_id: toConversationId, p_status: status, p_error: error,
  });
}

export async function logMessage(conversationId, role, content, meta = {}) {
  return rpc('log_message', { p_conversation_id: conversationId, p_role: role, p_content: content, p_meta: meta });
}

export async function evaluateTurn(conversationId, scorecard, messageId = null) {
  return rpc('evaluate_turn', { p_conversation_id: conversationId, p_scorecard: scorecard, p_message_id: messageId });
}

export async function endConversation(conversationId, outcome, summary = null) {
  return rpc('end_conversation', { p_conversation_id: conversationId, p_outcome: outcome, p_summary: summary });
}

// AQUÍ es donde el banco realmente pone límites (ej. extensión máxima de
// 15 días) — no en lo que el LLM "cree" que está bien. Si el cliente pide
// algo fuera de política, esto devuelve valid:false + una instrucción para
// que el composer lo explique en vez de aceptarlo.
export async function validateOffer(conversationId, offerCode, params = {}) {
  return rpc('validate_offer', { p_conversation_id: conversationId, p_offer_code: offerCode, p_params: params });
}

export async function registerCommitment(conversationId, offerCode, params, customerConfirmed) {
  return rpc('register_commitment', {
    p_conversation_id: conversationId,
    p_offer_code: offerCode,
    p_params: params,
    p_customer_confirmed: customerConfirmed,
  });
}

// Link de pago SIMULADO (tal como está diseñado en el esquema: genera una
// URL falsa tipo http://localhost:3000/pagar/<token>, no cobra nada real).
export async function createPaymentLink(conversationId, commitmentId) {
  return rpc('create_payment_link', { p_conversation_id: conversationId, p_commitment_id: commitmentId });
}

export async function getPromptVersion(key) {
  return withRetry(async () => {
    const { data, error } = await supabase
      .from('prompt_versions')
      .select('content, output_schema, variables')
      .eq('key', key)
      .eq('is_active', true)
      .maybeSingle();
    if (error) throw error;
    return data;
  });
}

export async function getRecentMessages(conversationId, limit = 8) {
  return withRetry(async () => {
    const { data, error } = await supabase
      .from('messages')
      .select('role, content, seq')
      .eq('conversation_id', conversationId)
      .order('seq', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return (data ?? []).reverse();
  });
}
