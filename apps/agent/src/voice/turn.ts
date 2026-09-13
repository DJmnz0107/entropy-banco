/**
 * Motor de turnos del agente de voz. Lo usan igual:
 *   · ElevenLabs (Custom LLM → /v1/chat/completions)
 *   · la llamada simulada (sin ElevenLabs, Gemini hace de cliente)
 *
 * Por turno: detecta interrupción → registra al cliente → lanza el supervisor en paralelo →
 * genera la respuesta con Gemini + tools (que pasan por Supabase) → registra al agente.
 */
import type { ChatCompletionMessageParam, ChatCompletionMessageToolCall } from 'openai/resources/chat/completions';
import { gemini, modelFor, withRetry } from '../lib/llm.js';
import { db, type Json } from '../lib/supabase.js';
import { buildSystemPrompt } from './prompt.js';
import { evaluateExchange } from './supervisor.js';
import { executeTool, toolDefinitions } from './tools.js';
import type { ConversationState } from './state.js';

export interface HistoryMessage { role: 'user' | 'assistant'; content: string }
export interface TurnResult { text: string; endCall: boolean; ttfbMs: number; totalMs: number }

const CRITICAL = new Set(['PROPUESTA', 'COMPROMISO', 'CONFIRMACION']);
const SLOW_TOOLS = new Set(['validar_oferta', 'registrar_compromiso', 'agendar_rellamada']);
const CLOSING_TOOLS = new Set(['finalizar_llamada', 'escalar_a_humano', 'agendar_rellamada', 'enviar_por_correo']);
const FAREWELL = 'Muchas gracias por su tiempo. Que tenga un excelente día.';

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
}): Promise<TurnResult> {
  const { state, history } = opts;
  const t0 = Date.now();
  let ttfb = -1;
  const emit = (chunk: string) => {
    if (!chunk) return;
    if (ttfb < 0) ttfb = Date.now() - t0;
    opts.onText?.(chunk);
  };

  // 1. Esperar (poco) a que termine la evaluación del turno anterior: el control llega a tiempo casi siempre
  await settle(state.supervisor, 700);

  const lastUser = [...history].reverse().find((m) => m.role === 'user')?.content?.trim() ?? '';
  const lastAssistant = [...history].reverse().find((m) => m.role === 'assistant')?.content ?? null;
  const closing = state.endCall;

  // 2. Interrupción: el historial trae el mensaje del agente truncado a lo que alcanzó a sonar
  if (state.lastAgentText && lastAssistant && lastAssistant.length < state.lastAgentText.length * 0.85) {
    const offer = CRITICAL.has(state.stage) ? state.lastPresentedOffer : null;
    const r = await db.logInterruption(state.conversationId, 'real', state.lastAgentMessageId, lastAssistant, lastUser, offer).catch(() => null);
    if (r?.control_message) state.pendingControl = r.control_message;
  } else if (lastUser) {
    const phrases = ((state.context.policies.interruption_policy as { backchannel_phrases?: string[] }).backchannel_phrases ?? []).map(normalize);
    if (phrases.includes(normalize(lastUser))) {
      void db.logInterruption(state.conversationId, 'backchannel', state.lastAgentMessageId, null, lastUser, null).catch(() => null);
    }
  }

  // 3. Registrar al cliente y evaluar en paralelo (no bloquea la respuesta)
  if (lastUser) {
    state.customerSpoke = true;
    const agentBefore = state.lastAgentText;
    state.customerLogged = db.logMessage(state.conversationId, 'customer', lastUser, { input_modality: 'audio' }).catch(() => null);
    const logged = state.customerLogged;
    state.supervisor = logged
      .then((m) => (closing ? undefined : evaluateExchange(state, agentBefore, lastUser, m?.message_id)))
      .catch((err) => console.warn(`[turn] supervisor: ${(err as Error).message}`));
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
  let text = '';
  let fillerSent = false;

  for (let round = 0; round < 4; round++) {
    const stream = await withRetry(() => gemini.chat.completions.create({
      model: model.modelId,
      temperature: model.temperature,
      max_tokens: model.maxTokens,
      messages,
      ...(tools ? { tools, tool_choice: 'auto' as const } : {}),
      stream: true,
    }));

    let roundText = '';
    const calls = new Map<number, ChatCompletionMessageToolCall & Record<string, unknown>>();
    for await (const chunk of stream) {
      const delta = chunk.choices[0]?.delta as (typeof chunk.choices[0]['delta'] & { tool_calls?: Array<Record<string, unknown>> }) | undefined;
      if (!delta) continue;
      if (delta.content) {
        roundText += delta.content;
        emit(delta.content);
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
    text += roundText;
    if (!calls.size) break;

    const toolCalls = [...calls.values()];
    const names = toolCalls.map((c) => (c as unknown as { function: { name: string } }).function.name);
    // frase de espera solo para herramientas que consultan/registran (las de cierre son instantáneas)
    if (opts.voice && !text && !fillerSent && names.some((n) => SLOW_TOOLS.has(n))) {
      fillerSent = true;
      emit('Permítame un momento... ');
    }
    let farewell: string | null = null;
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
    }
    // cierre: despedida lista, sin otra vuelta al modelo (ahorra 1–3 s)
    if (state.endCall && farewell && names.every((n) => CLOSING_TOOLS.has(n))) {
      if (!text.trim()) { emit(farewell); text += farewell; }
      break;
    }
  }

  if (!text.trim()) {
    text = state.endCall ? FAREWELL : 'Disculpe, ¿me podría repetir, por favor?';
    emit(text);
  }

  // 5. Registrar al agente (después del cliente para mantener el orden)
  await settle(state.customerLogged, 3000);
  const logged = await db.logMessage(state.conversationId, 'agent', text.trim(), {
    input_modality: 'audio', latency_ms: ttfb, ttfb_ms: ttfb, model_profile_key: model.key, prompt_version_key: 'voice.system@code-1',
  }).catch(() => null);
  state.lastAgentText = text.trim();
  state.lastAgentMessageId = logged?.message_id ?? null;
  state.turns += 1;

  return { text: text.trim(), endCall: state.endCall, ttfbMs: ttfb, totalMs: Date.now() - t0 };
}
