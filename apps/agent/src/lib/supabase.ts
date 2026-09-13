/**
 * Cliente service-role (SOLO servidor) + wrappers tipados de las RPC del contrato.
 * La lógica de negocio vive en Postgres: aquí no se decide nada.
 */
import { createClient } from '@supabase/supabase-js';
import { config } from '../config.js';

export const supabase = createClient(config.supabaseUrl ?? 'http://missing', config.supabaseServiceKey ?? 'missing', {
  auth: { persistSession: false, autoRefreshToken: false },
});

export type Json = Record<string, unknown>;

export async function rpc<T = Json>(fn: string, params: Json = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, params);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

// ─── Tipos del contrato (solo lo que el agente usa) ─────────────────────────
export interface Offer { code: string; name: string; offer_type?: string; pitch_script?: string; requires_approval?: boolean; generates_payment_link?: boolean }
export interface Stage { key: string; position: number; name: string; objective: string; instructions: string; criteria: string[]; allows_offers: boolean; is_terminal: boolean; suggested_outcome: string | null }

export interface ConversationContext {
  customer: { id: string; code: string; first_name: string; full_name: string; segment?: string; occupation?: string; contact_enabled: boolean; preferred_contact_window?: string };
  loan: { id: string; product_name: string; amount_due: number; amount_due_text: string; next_due_date: string; next_due_date_text: string; days_to_due: number; days_past_due: number } | null;
  risk: { score: number; band: string; probability_default: number; top_factors: Array<{ label: string; detail: string; points: number }> };
  signals: Array<{ type: string; label: string; detail: string }>;
  rules: { blocked: boolean; matched: Array<{ key: string; name: string }>; tone: string };
  offers: Offer[];
  max_offers_presented: number;
  constraints: Json;
  playbook: { key: string; name: string; stages: Stage[] };
  policies: { assistant_name: string; disclosure_text: string; pace_instructions: Record<string, string>; interruption_policy: Json; prohibited_phrases: string[] };
  history: { previous_conversations: Array<{ started_at: string; channel: string; outcome: string; summary: string }>; open_commitments: Json[] };
}

export interface StartResult { conversation_id: string; current_stage: string; simulated?: boolean; models: Json; context: ConversationContext }

export interface EvaluateResult {
  decision: 'stay' | 'advance' | 'jump' | 'escalate' | 'end' | 'ignored';
  from_stage: string; to_stage: string; pace: 'slow' | 'normal' | 'fast';
  rule: { id: string | null; label: string | null };
  is_terminal: boolean; suggested_outcome: string | null;
  stage: { key: string; name: string; objective: string; instructions: string; criteria: string[]; allows_offers: boolean };
  allowed_offers: Array<{ code: string; name: string }>;
  control_message: string; escalation_id: string | null;
}

export interface ValidateResult { valid: boolean; errors: string[]; offer_code: string; offer_name: string; offer_type: string; normalized_params: Json; terms_text: string; requires_approval: boolean; generates_payment_link: boolean; instruction: string }
export interface CommitmentResult { ok: boolean; receipt_code?: string; commitment_id?: string; status?: string; requires_approval?: boolean; summary?: string; errors?: string[]; instruction?: string; idempotent?: boolean }

export interface RunIntervention {
  intervention_id: string; customer_id: string; customer_code: string; full_name: string; first_name: string;
  phone_e164: string | null; email: string | null; contact_enabled: boolean;
  grade: string; action: string; channel: 'voice' | 'email' | 'whatsapp' | 'human' | null; priority: number;
  amount_at_risk: number; amount_due_text: string; due_date: string | null; due_date_text: string | null; product_name: string | null;
  why: string[]; offers: Array<{ code: string; name: string }>; education: { slug: string; title: string; duration_s: number } | null;
}
export interface RunPolicy { channel_by_grade: Record<string, string>; email_fallback: boolean; max_calls_per_run: number; max_simulated_calls_per_run: number; email_from: string }
export interface PreventionRun { run: Json & { id: string }; policy: RunPolicy; interventions: RunIntervention[] }

// ─── Wrappers ───────────────────────────────────────────────────────────────
export const db = {
  context: (customerId: string) => rpc<ConversationContext>('get_conversation_context', { p_customer_id: customerId }),
  nextBest: (customerId: string) => rpc<Json>('next_best_intervention', { p_customer_id: customerId }),

  startConversation: (customerId: string, channel: string, interventionId?: string | null, externalId?: string | null) =>
    rpc<StartResult>('start_conversation', {
      p_customer_id: customerId, p_channel: channel, p_direction: 'outbound',
      p_external_id: externalId ?? null, p_intervention_id: interventionId ?? null,
    }),
  startSimulated: (customerId: string, channel: string, interventionId?: string | null) =>
    rpc<StartResult>('start_simulated_conversation', { p_customer_id: customerId, p_channel: channel, p_intervention_id: interventionId ?? null }),

  logMessage: (conversationId: string, role: 'agent' | 'customer' | 'system' | 'tool', content: string, meta: Json = {}) =>
    rpc<{ message_id: string; seq: number }>('log_message', { p_conversation_id: conversationId, p_role: role, p_content: content, p_meta: meta }),
  evaluateTurn: (conversationId: string, scorecard: Json, messageId?: string, meta: Json = {}) =>
    rpc<EvaluateResult>('evaluate_turn', { p_conversation_id: conversationId, p_scorecard: scorecard, p_message_id: messageId ?? null, p_meta: meta }),
  logInterruption: (conversationId: string, kind: 'real' | 'backchannel' | 'false_barge_in', messageId: string | null, heardText: string | null, customerText: string | null, offerCode: string | null) =>
    rpc<{ must_restate_terms: boolean; offers_to_restate: string[]; control_message: string }>('log_interruption', {
      p_conversation_id: conversationId, p_kind: kind, p_message_id: messageId, p_heard_text: heardText,
      p_played_ms: null, p_total_ms: null, p_customer_text: customerText, p_offer_code: offerCode,
    }),
  validateOffer: (conversationId: string, code: string, params: Json) =>
    rpc<ValidateResult>('validate_offer', { p_conversation_id: conversationId, p_offer_code: code, p_params: params }),
  registerCommitment: (conversationId: string, code: string, params: Json, confirmed: boolean) =>
    rpc<CommitmentResult>('register_commitment', { p_conversation_id: conversationId, p_offer_code: code, p_params: params, p_customer_confirmed: confirmed }),
  createPaymentLink: (conversationId: string, amount?: number) =>
    rpc<{ token: string; url: string; amount: number; amount_text: string }>('create_payment_link', { p_conversation_id: conversationId, p_amount: amount ?? null }),
  requestEscalation: (conversationId: string, reason: string) =>
    rpc<{ escalation_id: string }>('request_escalation', { p_conversation_id: conversationId, p_reason: reason, p_priority: 'high', p_trigger: 'AGENT_TOOL' }),
  endConversation: (conversationId: string, outcome: string, summary?: string | null, meta: Json = {}) =>
    rpc<{ ok: boolean; outcome: string; risk_before: number; risk_after: number; commitment_receipt: string | null; idempotent?: boolean }>('end_conversation', {
      p_conversation_id: conversationId, p_outcome: outcome, p_summary: summary ?? null, p_meta: meta,
    }),
  recordModelUsage: (conversationId: string, modelKey: string, usage: Json) =>
    rpc<{ cost_usd: number }>('record_model_usage', { p_conversation_id: conversationId, p_model_key: modelKey, p_usage: usage }),
  sendEducation: (customerId: string, conversationId: string | null, channel: 'email' | 'whatsapp', slug?: string | null) =>
    rpc<{ ok: boolean; delivery_id?: string; slug?: string; title?: string; url?: string; duration_s?: number }>('send_education', {
      p_customer_id: customerId, p_conversation_id: conversationId, p_slug: slug ?? null, p_reason: 'corrida', p_channel: channel,
    }),
  syncPlanStep: (interventionId: string | null, stepType: string, status: string, conversationId?: string | null, detail: Json = {}) =>
    interventionId ? rpc<null>('sync_plan_step', { p_intervention_id: interventionId, p_step_type: stepType, p_status: status, p_conversation_id: conversationId ?? null, p_detail: detail }) : Promise.resolve(null),

  runPrevention: (filters: Json, createdBy: string) => rpc<Json & { run_id: string }>('run_prevention', { p_filters: filters, p_created_by: createdBy }),
  getRun: (runId: string, channel?: string) => rpc<PreventionRun>('get_prevention_run', { p_run_id: runId, p_channel: channel ?? null }),
  markRunDispatched: (runId: string, summary: Json) => rpc<null>('mark_run_dispatched', { p_run_id: runId, p_summary: summary }),

  async conversationRow(conversationId: string) {
    const { data, error } = await supabase.from('conversations')
      .select('id, customer_id, intervention_id, channel, status, current_stage, external_id, is_synthetic, commitment_id, turn_count, started_at')
      .eq('id', conversationId).maybeSingle();
    if (error) throw new Error(`conversations: ${error.message}`);
    return data as null | { id: string; customer_id: string; intervention_id: string | null; channel: string; status: string; current_stage: string; external_id: string | null; is_synthetic: boolean; commitment_id: string | null; turn_count: number; started_at: string };
  },
  async setExternalId(conversationId: string, externalId: string) {
    await supabase.from('conversations').update({ external_id: externalId }).eq('id', conversationId);
  },
  async conversationByExternalId(externalId: string) {
    const { data } = await supabase.from('conversations').select('id').eq('external_id', externalId).maybeSingle();
    return (data as { id: string } | null)?.id ?? null;
  },
  async customerByCode(code: string) {
    const { data } = await supabase.from('customers').select('id, email, phone_e164, contact_enabled, first_name, full_name').eq('customer_code', code).maybeSingle();
    return data as null | { id: string; email: string | null; phone_e164: string | null; contact_enabled: boolean; first_name: string; full_name: string };
  },
  async customerContact(customerId: string) {
    const { data } = await supabase.from('customers').select('id, customer_code, email, phone_e164, contact_enabled, first_name, full_name').eq('id', customerId).maybeSingle();
    return data as null | { id: string; customer_code: string; email: string | null; phone_e164: string | null; contact_enabled: boolean; first_name: string; full_name: string };
  },
  async interventionForCustomer(customerId: string) {
    const { data } = await supabase.from('interventions').select('id, grade, action, next_best')
      .eq('customer_id', customerId).in('status', ['scheduled', 'dispatched']).order('created_at', { ascending: false }).limit(1).maybeSingle();
    return data as null | { id: string; grade: string | null; action: string | null; next_best: Json | null };
  },
  async interventionById(id: string) {
    const { data } = await supabase.from('interventions').select('id, grade, action, next_best').eq('id', id).maybeSingle();
    return data as null | { id: string; grade: string | null; action: string | null; next_best: Json | null };
  },
  async commitment(commitmentId: string) {
    const { data } = await supabase.from('commitments').select('id, offer_code, receipt_code, terms_text, amount, committed_date, status, requires_approval').eq('id', commitmentId).maybeSingle();
    return data as null | { id: string; offer_code: string; receipt_code: string; terms_text: string; amount: number | null; committed_date: string | null; status: string; requires_approval: boolean };
  },
  async activePolicy() {
    const { data } = await supabase.from('agent_policies').select('*').eq('is_active', true).maybeSingle();
    return data as null | { default_models: Record<string, string>; payment_link_base_url: string; email_from: string; email_fallback: boolean; max_calls_per_run: number; max_simulated_calls_per_run: number };
  },
  async modelProfile(key: string) {
    const { data } = await supabase.from('ai_model_profiles').select('key, model_id, params, provider').eq('key', key).maybeSingle();
    return data as null | { key: string; model_id: string; params: Json; provider: string };
  },
  async prompt(key: string) {
    const { data } = await supabase.from('prompt_versions').select('key, version, content, output_schema').eq('key', key).eq('is_active', true).maybeSingle();
    return data as null | { key: string; version: number; content: string; output_schema: Json | null };
  },
  async criteria(keys: string[]) {
    if (!keys.length) return [];
    const { data } = await supabase.from('evaluation_criteria').select('key, label, description, options').in('key', keys);
    return (data ?? []) as Array<{ key: string; label: string; description: string; options: unknown }>;
  },
};
