/**
 * Motor de turnos del agente de voz. Lo usan igual:
 *   · ElevenLabs (Custom LLM → /v1/chat/completions)
 *   · la llamada simulada (sin ElevenLabs, Gemini hace de cliente)
 *
 * Por turno: detecta interrupción → registra al cliente → lanza el supervisor en paralelo →
 * genera la respuesta con Gemini + tools (que pasan por Supabase) → registra al agente.
 */
import type { ChatCompletionMessageParam, ChatCompletionMessageToolCall } from 'openai/resources/chat/completions';
import { gemini, modelFor, withModelFallback } from '../lib/llm.js';
import { db, supabase, type Json } from '../lib/supabase.js';
import { buildSystemPrompt } from './prompt.js';
import { evaluateExchange } from './supervisor.js';
import { executeTool, toolDefinitions } from './tools.js';
import { GUARD_REPLIES, OutputGuard, extractDates, inspectCustomer } from './guardrails.js';
import { todaySv } from './prompt.js';
import type { ConversationState } from './state.js';

export interface HistoryMessage { role: 'user' | 'assistant'; content: string }
export interface TurnResult { text: string; endCall: boolean; ttfbMs: number; totalMs: number }

const CRITICAL = new Set(['PROPUESTA', 'COMPROMISO', 'CONFIRMACION']);
// Frase de espera solo donde el cliente ya dijo "sí" y hay escritura en BD. En validar_oferta la pausa tras
// "Permítame un momento" hacía que el cliente siguiera hablando, ElevenLabs cancelaba y se repetían las condiciones.
const SLOW_TOOLS = new Set(['registrar_compromiso']);
const voiceDateGuard = process.env.DATE_GUARD !== 'false';
const CLOSING_TOOLS = new Set(['finalizar_llamada', 'escalar_a_humano', 'agendar_rellamada', 'enviar_por_correo', 'registrar_desvio']);
const FAREWELL = 'Agradezco mucho su tiempo y disposición para conversar. Le deseo un excelente día.';
export const PROMPT_VERSION = 'voice.system@code-2';

function normalize(text: string): string {
  return text.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-zñ ]/g, '').trim();
}

async function settle(p: Promise<unknown> | null, ms: number): Promise<void> {
  if (!p) return;
  await Promise.race([p.catch(() => null), new Promise((r) => setTimeout(r, ms))]);
}

export async function runAgentTurn(opts: {
  state: ConversationState;
  history: HistoryMessage[];           // incluye el último mensaje del cliente
  onText?: (chunk: string) => void;
  voice?: boolean;
  isStale?: () => boolean;             // ElevenLabs canceló este turno (el cliente siguió hablando)
}): Promise<TurnResult> {
  const { state, history } = opts;
  const stale = () => opts.isStale?.() ?? false;
  const t0 = Date.now();
  let ttfb = -1;
  const emit = (chunk: string) => {
    if (!chunk || stale()) return;
    if (ttfb < 0) ttfb = Date.now() - t0;
    opts.onText?.(chunk);
  };

  // 1. Esperar (poco) a que termine la evaluación del turno anterior: el control llega a tiempo casi siempre
  await settle(state.supervisor, 700);

  // G2: el texto del cliente se revisa y se enmascara (tarjetas, cuentas) antes de guardarlo o mandarlo al modelo
  const lastUserIdx = history.map((m) => m.role).lastIndexOf('user');
  const inspection = inspectCustomer(history[lastUserIdx]?.content?.trim() ?? '');
  if (lastUserIdx >= 0) history[lastUserIdx] = { role: 'user', content: inspection.redacted };
  const lastUser = inspection.redacted;
  const lastAssistant = [...history].reverse().find((m) => m.role === 'assistant')?.content ?? null;
  const closing = state.endCall;

  // 2. Interrupción: ElevenLabs manda el mensaje del agente truncado a lo que alcanzó a sonar.
  //    Solo cuenta si es el MISMO mensaje cortado (prefijo); si no, venía de un turno cancelado que nunca se registró.
  const heard = lastAssistant?.replace(/(\.\.\.|…)\s*$/, '').trim() ?? '';
  const userIndex = history.filter((m) => m.role === 'user').length;
  const repeatedUser = state.lastUser?.index === userIndex;
  const truncated = !repeatedUser && !!state.lastAgentText && !!heard
    && heard.length < state.lastAgentText.length * 0.85 && state.lastAgentText.startsWith(heard.slice(0, Math.max(8, heard.length - 3)));
  if (truncated) {
    // solo se invalidan condiciones si ese mensaje las llevaba
    const r = await db.logInterruption(state.conversationId, state.lastTermsOffer ? 'real' : 'false_barge_in', state.lastAgentMessageId, heard, lastUser, state.lastTermsOffer).catch(() => null);
    if (r?.control_message && state.lastTermsOffer) state.pendingControl = r.control_message;
  } else if (lastUser && !repeatedUser && !/\?\s*$/.test(lastAssistant ?? '')) {
    // "sí" después de una pregunta es una respuesta, no un backchannel
    const phrases = ((state.context.policies.interruption_policy as { backchannel_phrases?: string[] }).backchannel_phrases ?? []).map(normalize);
    if (phrases.includes(normalize(lastUser))) {
      void db.logInterruption(state.conversationId, 'backchannel', state.lastAgentMessageId, null, lastUser, null).catch(() => null);
    }
  }

  // 3. Registrar al cliente (sin duplicar reintentos de ElevenLabs) y evaluar en paralelo
  if (lastUser && !(repeatedUser && state.lastUser?.text === lastUser)) {
    state.customerSpoke = true;
    const agentBefore = state.lastAgentText;
    if (repeatedUser && state.lastUser?.messageId) {
      // mismo turno del cliente con transcripción más larga: se actualiza el mensaje
      const messageId = state.lastUser.messageId;
      state.lastUser.text = lastUser;
      void supabase.from('messages').update({ content: lastUser }).eq('id', messageId).then(() => null);
      state.customerLogged = Promise.resolve({ message_id: messageId });
    } else {
      const entry: { index: number; text: string; messageId: string | null } = { index: userIndex, text: lastUser, messageId: null };
      state.lastUser = entry;
      state.customerLogged = db.logMessage(state.conversationId, 'customer', lastUser, { input_modality: 'audio' })
        .then((m) => { entry.messageId = m.message_id; return m; }).catch(() => null);
    }
    const logged = state.customerLogged;
    state.supervisor = logged
      .then((m) => (closing ? undefined : evaluateExchange(state, agentBefore, lastUser, m?.message_id)))
      .catch((err) => console.warn(`[turn] supervisor: ${(err as Error).message}`));
  }

  // G2: inyección, datos sensibles o agresión → respuesta fija sin pasar por el modelo
  if (!closing && lastUser && !repeatedUser && inspection.risks.length) {
    const risk = inspection.risks.includes('abuse') ? 'abuse' : inspection.risks.includes('sensitive_data') ? 'sensitive_data' : 'injection';
    let reply: string;
    if (risk === 'abuse') {
      state.abuse += 1;
      reply = state.abuse >= 2 ? GUARD_REPLIES.abuse_2 : GUARD_REPLIES.abuse_1;
      if (state.abuse >= 2) { state.endCall = true; state.outcome = state.outcome ?? 'FOLLOW_UP_REQUIRED'; }
    } else if (risk === 'injection') {
      state.offTopic += 1;
      reply = state.offTopic >= 3 ? GUARD_REPLIES.off_topic_3 : GUARD_REPLIES.injection;
      if (state.offTopic >= 3) { state.endCall = true; state.outcome = state.outcome ?? 'FOLLOW_UP_REQUIRED'; }
    } else {
      reply = GUARD_REPLIES.sensitive_data;
    }
    void db.logEvent(state.conversationId, 'guardrail_triggered', { capa: 'G2', tipo: risk, texto: lastUser.slice(0, 160) }, 'warning');
    emit(reply);
    if (stale()) return { text: reply, endCall: false, ttfbMs: ttfb, totalMs: Date.now() - t0 };
    return finishTurn(state, reply, ttfb, t0, null, 'guardrail');
  }

  // 4. Generar respuesta con tools
  const model = await modelFor('composer');
  const system = buildSystemPrompt(state)
    + (closing ? `\n\n# CIERRE\nLa conversación ya terminó (${state.outcome ?? 'cierre'}). Despídete con calidez en UNA frase. No ofrezcas nada más.` : '');
  const messages: ChatCompletionMessageParam[] = [
    { role: 'system', content: system },
    ...history.map((m) => ({ role: m.role, content: m.content }) as ChatCompletionMessageParam),
  ];
  if (!history.length) messages.push({ role: 'user', content: '¿Aló?' });

  const tools = closing ? undefined : toolDefinitions(state);
  let text = '';                        // lo que realmente se envió a la voz (ya revisado por G4)
  let fillerSent = false;
  const say = (chunk: string) => { text += chunk; emit(chunk); };
  const allowed = () => [
    ...Object.values(state.terms),
    ...state.context.offers.map((o) => o.pitch_script ?? ''),
  ].join(' ');
  // fechas que se pueden afirmar: vencimiento, hoy, condiciones validadas y máximos que devolvió la BD
  const allowedDates = () => new Set(extractDates([
    state.context.loan?.next_due_date_text ?? '', todaySv(), ...Object.values(state.terms), ...state.allowedDateTexts,
  ].join(' . ')));
  const guard = new OutputGuard(say, allowed, voiceDateGuard ? allowedDates : null);
  let dateCorrections = 0;
  let termsOffer: string | null = null;

  for (let round = 0; round < 4; round++) {
    const stream = await withModelFallback(model.modelId, (modelId) => gemini.chat.completions.create({
      model: modelId,
      temperature: model.temperature,
      max_tokens: model.maxTokens,
      messages,
      ...(tools ? { tools, tool_choice: 'auto' as const } : {}),
      stream: true,
    }, { timeout: 5000 }));   // en voz, más de 5 s sin respuesta es silencio: mejor otro modelo

    let roundText = '';
    const calls = new Map<number, ChatCompletionMessageToolCall & Record<string, unknown>>();
    for await (const chunk of stream) {
      if (stale()) break;
      const delta = chunk.choices[0]?.delta as (typeof chunk.choices[0]['delta'] & { tool_calls?: Array<Record<string, unknown>> }) | undefined;
      if (!delta) continue;
      if (delta.content) {
        roundText += delta.content;
        guard.push(delta.content);
      }
      for (const tc of delta.tool_calls ?? []) {
        const index = (tc.index as number | undefined) ?? calls.size;
        const prev = calls.get(index);
        const fn = (tc.function ?? {}) as { name?: string; arguments?: string };
        if (!prev) {
          // se conserva el objeto completo (p. ej. firmas de pensamiento de Gemini en extra_content)
          const { index: _i, ...rest } = tc;
          calls.set(index, { ...(rest as object), type: 'function', id: (tc.id as string) ?? `call_${index}`, function: { name: fn.name ?? '', arguments: fn.arguments ?? '' } } as ChatCompletionMessageToolCall & Record<string, unknown>);
        } else {
          const pf = (prev as unknown as { function: { name: string; arguments: string } }).function;
          if (fn.name) pf.name = fn.name;
          if (fn.arguments) pf.arguments += fn.arguments;
        }
      }
    }
    guard.flush();
    if (stale()) break;
    // G4 fechas: iba a afirmar una fecha que el banco no validó → se corta y se le pide validar en otra vuelta
    if (guard.halted && dateCorrections < 1 && round < 3) {
      dateCorrections += 1;
      const said = text.trim();
      if (said) messages.push({ role: 'assistant', content: said });
      messages.push({ role: 'user', content: '(Nota interna del sistema, no la leas: ibas a mencionar una fecha que el banco no ha validado. Llama validar_oferta con la fecha que dijo el cliente ANTES de mencionarla y usa solo lo que devuelva.)' });
      guard.resume();
      continue;
    }
    if (!calls.size) break;

    const toolCalls = [...calls.values()];
    // un registrar_compromiso repetido (ya hay recibo) no cuenta para la frase de espera ni impide el cierre rápido
    const names = toolCalls.map((c) => (c as unknown as { function: { name: string } }).function.name)
      .filter((n) => !(n === 'registrar_compromiso' && state.commitment));
    // frase de espera solo para herramientas que consultan/registran (las de cierre son instantáneas)
    if (opts.voice && !text && !fillerSent && names.some((n) => SLOW_TOOLS.has(n))) {
      fillerSent = true;
      say('Permítame un momento... ');
    }
    let farewell: string | null = null;
    let fixedReply: string | null = null;
    messages.push({ role: 'assistant', content: roundText || null, tool_calls: toolCalls } as ChatCompletionMessageParam);
    for (const call of toolCalls) {
      const fn = (call as unknown as { function: { name: string; arguments: string } }).function;
      let args: Json = {};
      try { args = JSON.parse(fn.arguments || '{}') as Json; } catch { /* argumentos inválidos → {} */ }
      let result: Json;
      try {
        result = await executeTool(state, fn.name, args);
      } catch (err) {
        result = { ok: false, error: (err as Error).message };
      }
      void db.logMessage(state.conversationId, 'tool', `${fn.name}(${JSON.stringify(args)}) → ${JSON.stringify(result).slice(0, 600)}`, { tool: fn.name }).catch(() => null);
      messages.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify(result) });
      if (typeof result.despedida === 'string' && result.despedida) farewell = result.despedida;
      if (typeof result.respuesta_fija === 'string' && result.respuesta_fija) fixedReply = result.respuesta_fija;
      if (fn.name === 'validar_oferta' && result.valida === true) termsOffer = String((args as { codigo_oferta?: string }).codigo_oferta ?? '') || null;
    }
    // cierre: despedida lista, sin otra vuelta al modelo (ahorra 1–3 s)
    if (state.endCall && farewell && names.length && names.every((n) => CLOSING_TOOLS.has(n))) {
      if (!text.trim()) say(farewell);
      break;
    }
    // desvío de tema: la respuesta la decide el servidor (protocolo 1-2-3), sin otra vuelta al modelo
    if (fixedReply && names.every((n) => n === 'registrar_desvio')) {
      say(fixedReply);
      break;
    }
  }

  // Turno cancelado por ElevenLabs: no se dijo, así que no se registra ni cuenta como último mensaje
  if (stale()) {
    return { text: text.trim(), endCall: false, ttfbMs: ttfb, totalMs: Date.now() - t0 };
  }

  if (guard.violations.length) {
    void db.logEvent(state.conversationId, 'guardrail_triggered', { capa: 'G4', violaciones: guard.violations }, 'warning');
  }
  if (!text.trim()) say(state.endCall ? FAREWELL : 'Disculpe, ¿me podría repetir, por favor?');

  return finishTurn(state, text, ttfb, t0, termsOffer, model.key);
}

/** 5. Registrar al agente (después del cliente para mantener el orden). */
async function finishTurn(state: ConversationState, spoken: string, ttfb: number, t0: number, termsOffer: string | null, modelKey: string): Promise<TurnResult> {
  const text = spoken.trim();
  await settle(state.customerLogged, 3000);
  const logged = await db.logMessage(state.conversationId, 'agent', text, {
    input_modality: 'audio', latency_ms: ttfb, ttfb_ms: ttfb, model_profile_key: modelKey, prompt_version_key: PROMPT_VERSION,
  }).catch(() => null);
  state.lastAgentText = text;
  state.lastAgentMessageId = logged?.message_id ?? null;
  state.lastTermsOffer = termsOffer;
  state.turns += 1;
  return { text, endCall: state.endCall, ttfbMs: ttfb, totalMs: Date.now() - t0 };
}
