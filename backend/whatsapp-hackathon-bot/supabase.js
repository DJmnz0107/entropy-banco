import { createClient } from '@supabase/supabase-js';

// service_role: las funciones RPC del motor (start_conversation, log_message, evaluate_turn...)
// están bloqueadas para "anon" a propósito (ver 0900_security_realtime.sql). Este backend
// corre en servidor, nunca en el navegador, así que puede usar la llave secreta.
const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

async function rpc(fn, params = {}) {
  const { data, error } = await supabase.rpc(fn, params);
  if (error) throw error;
  return data;
}

export async function findCustomerByPhone(phone) {
  return rpc('find_customer_by_phone', { p_phone: phone });
}

export async function getActiveConversation(customerId, channel) {
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
}

export async function startConversation(customerId, channel, direction = 'inbound') {
  return rpc('start_conversation', { p_customer_id: customerId, p_channel: channel, p_direction: direction });
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

export async function getPromptVersion(key) {
  const { data, error } = await supabase
    .from('prompt_versions')
    .select('content, output_schema, variables')
    .eq('key', key)
    .eq('is_active', true)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function getRecentMessages(conversationId, limit = 8) {
  const { data, error } = await supabase
    .from('messages')
    .select('role, content, seq')
    .eq('conversation_id', conversationId)
    .order('seq', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return (data ?? []).reverse();
}
