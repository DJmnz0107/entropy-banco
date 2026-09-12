import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  throw new Error('[supabase] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
}

/**
 * Service-role client — only used server-side.
 * Never expose this key to the browser or NEXT_PUBLIC_ env vars.
 */
export const supabase = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ---------------------------------------------------------------------------
// Typed RPC helpers
// ---------------------------------------------------------------------------

export async function rpc<T = unknown>(
  fn: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  const { data, error } = await supabase.rpc(fn, params);
  if (error) throw new Error(`[supabase.rpc] ${fn}: ${error.message}`);
  return data as T;
}

// --- Individual typed wrappers ---

export interface ConversationContext {
  customer: {
    id: string;
    code: string;
    full_name: string;
    contact_enabled: boolean;
  };
  loan: {
    amount_due_text: string;
    next_due_date_text: string;
    days_to_due: number;
    status: string;
  };
  risk: {
    score: number;
    band: string;
    factors: string[];
  };
  offers: Array<{
    code: string;
    name: string;
    pitch: string;
    type: string;
  }>;
  max_offers_presented: number;
  playbook: {
    key: string;
    name: string;
    stages: Array<{
      key: string;
      name: string;
      objective: string;
      instructions: string;
      criteria: unknown[];
      exit_rules: unknown;
      allows_offers: boolean;
    }>;
  };
  policies: {
    disclosure_script: string;
    prohibited_phrases: string[];
    backchannel_phrases: string[];
    critical_stages: string[];
    silence_config: Record<string, unknown>;
  };
  history: {
    previous_conversations: unknown[];
    open_commitments: unknown[];
  };
  facts: Record<string, unknown>;
  rules: {
    tone: string;
    blocked: boolean;
    block_reason: string | null;
  };
}

export interface StartConversationResult {
  conversation_id: string;
  current_stage: string;
  models: {
    voice_mode: string;
    voice_realtime: {
      key: string;
      model_id: string;
      params: {
        temperature?: number;
        voice_name?: string;
        [k: string]: unknown;
      };
      vad_config: Record<string, unknown>;
      interruption_config: {
        backchannel_phrases: string[];
        critical_stages: string[];
        [k: string]: unknown;
      };
    };
    supervisor: {
      key: string;
      model_id: string;
      params: Record<string, unknown>;
    };
    [k: string]: unknown;
  };
  prompt_versions: Record<string, number>;
  experiment: unknown;
  warnings: string[];
  context: ConversationContext;
}

export interface LogMessageResult {
  message_id: string;
  seq: number;
  stage_key: string;
}

export interface EvaluateTurnResult {
  decision: 'stay' | 'advance' | 'jump' | 'escalate' | 'end';
  from_stage: string;
  to_stage: string;
  rule: { id: string; label: string } | null;
  pace: 'slow' | 'normal' | 'fast';
  is_terminal: boolean;
  suggested_outcome: string | null;
  stage: {
    key: string;
    name: string;
    objective: string;
    instructions: string;
    criteria: unknown[];
    allows_offers: boolean;
  };
  allowed_offers: Array<{ code: string; name: string; pitch: string }>;
  control_message: string;
  escalation_id: string | null;
}

export interface ValidateOfferResult {
  valid: boolean;
  errors: string[];
  normalized_params: Record<string, unknown>;
  terms_text: string;
  requires_approval: boolean;
  instruction: string;
}

export interface RegisterCommitmentResult {
  ok: boolean;
  receipt_code: string | null;
  commitment_id: string | null;
  status: string;
  summary: string;
  next_steps: string;
  instruction: string;
  errors: string[] | null;
}

export interface CreatePaymentLinkResult {
  token: string;
  url: string;
  amount: number;
  amount_text: string;
  expires_at: string;
}

export interface LogInterruptionResult {
  must_restate_terms: boolean;
  offers_to_restate: string[];
  control_message: string;
}

export interface LogSilenceResult {
  action: 'reprompt' | 'end';
  control_message: string;
  suggested_outcome?: string;
  suggest_handoff?: string;
}

export interface EndConversationResult {
  risk_before: number;
  risk_after: number;
  commitment_receipt: string | null;
  avg_latency_ms: number | null;
  p95_latency_ms: number | null;
}

export const db = {
  getConversationContext: (customerId: string) =>
    rpc<ConversationContext>('get_conversation_context', { p_customer_id: customerId }),

  startConversation: (
    customerId: string,
    channel: string,
    direction: string,
    opts: Record<string, unknown> = {},
  ) =>
    rpc<StartConversationResult>('start_conversation', {
      p_customer_id: customerId,
      p_channel: channel,
      p_direction: direction,
      ...opts,
    }),

  logMessage: (
    conversationId: string,
    role: 'agent' | 'customer' | 'system' | 'tool',
    content: string,
    meta: Record<string, unknown> = {},
  ) =>
    rpc<LogMessageResult>('log_message', {
      p_conversation_id: conversationId,
      p_role: role,
      p_content: content,
      p_meta: meta,
    }),

  evaluateTurn: (
    conversationId: string,
    scorecard: Record<string, unknown>,
    messageId?: string,
  ) =>
    rpc<EvaluateTurnResult>('evaluate_turn', {
      p_conversation_id: conversationId,
      p_scorecard: scorecard,
      ...(messageId ? { p_message_id: messageId } : {}),
    }),

  validateOffer: (
    conversationId: string,
    offerCode: string,
    params: Record<string, unknown> = {},
  ) =>
    rpc<ValidateOfferResult>('validate_offer', {
      p_conversation_id: conversationId,
      p_offer_code: offerCode,
      p_params: params,
    }),

  registerCommitment: (
    conversationId: string,
    offerCode: string,
    params: Record<string, unknown>,
    customerConfirmed: boolean,
  ) =>
    rpc<RegisterCommitmentResult>('register_commitment', {
      p_conversation_id: conversationId,
      p_offer_code: offerCode,
      p_params: params,
      p_customer_confirmed: customerConfirmed,
    }),

  createPaymentLink: (conversationId: string) =>
    rpc<CreatePaymentLinkResult>('create_payment_link', {
      p_conversation_id: conversationId,
    }),

  logInterruption: (
    conversationId: string,
    kind: 'real' | 'backchannel' | 'false_barge_in',
    messageId: string,
    heardText: string,
    playedMs: number,
    totalMs: number,
    customerText: string,
    offerCode?: string,
  ) =>
    rpc<LogInterruptionResult>('log_interruption', {
      p_conversation_id: conversationId,
      p_kind: kind,
      p_message_id: messageId,
      p_heard_text: heardText,
      p_played_ms: playedMs,
      p_total_ms: totalMs,
      p_customer_text: customerText,
      ...(offerCode ? { p_offer_code: offerCode } : {}),
    }),

  logSilence: (conversationId: string) =>
    rpc<LogSilenceResult>('log_silence', {
      p_conversation_id: conversationId,
    }),

  endConversation: (
    conversationId: string,
    outcome: string,
    summary?: string,
    meta: Record<string, unknown> = {},
  ) =>
    rpc<EndConversationResult>('end_conversation', {
      p_conversation_id: conversationId,
      p_outcome: outcome,
      ...(summary ? { p_summary: summary } : {}),
      p_meta: meta,
    }),

  recordModelUsage: (
    conversationId: string,
    modelKey: string,
    usage: Record<string, unknown>,
  ) =>
    rpc<void>('record_model_usage', {
      p_conversation_id: conversationId,
      p_model_key: modelKey,
      p_usage: usage,
    }),

  requestEscalation: (
    conversationId: string,
    reason: string,
    priority = 'high',
    trigger?: string,
  ) =>
    rpc<{ escalation_id: string }>('request_escalation', {
      p_conversation_id: conversationId,
      p_reason: reason,
      p_priority: priority,
      ...(trigger ? { p_trigger: trigger } : {}),
    }),

  setDemoContact: (customerCode: string, phone: string) =>
    rpc<void>('set_demo_contact', {
      p_customer_code: customerCode,
      p_phone: phone,
    }),
};
