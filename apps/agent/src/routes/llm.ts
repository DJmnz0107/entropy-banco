/**
 * POST /v1/chat/completions — ElevenLabs "Custom LLM" (formato OpenAI, SSE).
 * ElevenLabs manda el historial completo en cada turno; nosotros aplicamos control, tools y registro.
 */
import { Hono, type Context } from 'hono';
import { streamSSE } from 'hono/streaming';
import { randomUUID } from 'node:crypto';
import { config } from '../config.js';
import { db } from '../lib/supabase.js';
import { getState } from '../voice/state.js';
import { runAgentTurn, type HistoryMessage } from '../voice/turn.js';

export const llmRouter = new Hono();

type IncomingMessage = { role: string; content?: string | Array<{ type?: string; text?: string }> | null };
const testConversations = new Map<string, string>();   // conversación de ElevenLabs → nuestra (pruebas desde el panel)

function textOf(content: IncomingMessage['content']): string {
  if (!content) return '';
  if (typeof content === 'string') return content;
  return content.map((p) => p.text ?? '').join('');
}

async function resolveConversationId(messages: IncomingMessage[], extra: Record<string, unknown> | undefined): Promise<string | null> {
  const system = messages.filter((m) => m.role === 'system').map((m) => textOf(m.content)).join('\n');
  const direct = system.match(/CONVERSATION_ID=([0-9a-f-]{36})/i)?.[1] ?? (extra?.conversation_id as string | undefined);
  if (direct) return direct;

  // Prueba desde el panel de ElevenLabs sin corrida: conversación simulada con el cliente de prueba
  const elId = system.match(/EL_CONVERSATION=([\w-]+)/)?.[1];
  if (!config.allowTestConversations || !elId) return null;
  const known = testConversations.get(elId);
  if (known) return known;
  const customer = await db.customerByCode(config.testCustomerCode);
  if (!customer) return null;
  const start = await db.startSimulated(customer.id, 'voice', null);
  testConversations.set(elId, start.conversation_id);
  await db.setExternalId(start.conversation_id, elId);
  return start.conversation_id;
}

// Autenticación: header Authorization: Bearer <CUSTOM_LLM_SECRET>, o el secreto en la ruta /llm/<secreto>/...
// (ElevenLabs guarda la URL del Custom LLM; así no hace falta crear un secreto de workspace).
function authorized(c: { req: { header: (n: string) => string | undefined; param: (n: string) => string | undefined } }): boolean {
  if (!config.customLlmSecret) return true;
  return c.req.header('authorization') === `Bearer ${config.customLlmSecret}` || c.req.param('token') === config.customLlmSecret;
}

// ElevenLabs puede usar la URL tal cual o agregarle /chat/completions: aceptamos todas las formas
for (const path of ['/v1/chat/completions', '/chat/completions', '/llm/:token', '/llm/:token/chat/completions', '/llm/:token/v1/chat/completions']) {
  llmRouter.post(path, (c) => handleCompletion(c));
}

async function handleCompletion(c: Context) {
  if (!authorized(c)) return c.json({ error: 'No autorizado' }, 401);
  const body = (await c.req.json().catch(() => ({}))) as {
    messages?: IncomingMessage[]; tools?: Array<{ function?: { name?: string } }>; elevenlabs_extra_body?: Record<string, unknown>;
  };
  const messages = body.messages ?? [];
  const canEndCall = (body.tools ?? []).some((t) => t.function?.name === 'end_call');
  const id = `chatcmpl-${randomUUID()}`;
  const created = Math.floor(Date.now() / 1000);
  const chunk = (delta: Record<string, unknown>, finish: string | null = null) =>
    JSON.stringify({ id, object: 'chat.completion.chunk', created, model: 'banca-inteligente', choices: [{ index: 0, delta, finish_reason: finish }] });

  return streamSSE(c, async (stream) => {
    let conversationId: string | null = null;
    let aborted = false;
    stream.onAbort(() => { aborted = true; });
    try {
      conversationId = await resolveConversationId(messages, body.elevenlabs_extra_body);
      if (!conversationId) {
        await stream.writeSSE({ data: chunk({ role: 'assistant', content: 'Disculpe, tuvimos un inconveniente técnico. Le contactaremos más tarde.' }) });
        await stream.writeSSE({ data: chunk({}, 'stop') });
        await stream.writeSSE({ data: '[DONE]' });
        return;
      }
      const state = await getState(conversationId);
      // Si el cliente sigue hablando, ElevenLabs cancela este request y manda otro: el viejo deja de hablar y de registrar
      const seq = ++state.requestSeq;
      const isStale = () => aborted || c.req.raw.signal.aborted || state.requestSeq !== seq;
      const history: HistoryMessage[] = messages
        .filter((m) => m.role === 'user' || m.role === 'assistant')
        .map((m) => ({ role: m.role as 'user' | 'assistant', content: textOf(m.content) }))
        .filter((m) => m.content.trim() !== '');

      let first = true;
      const result = await runAgentTurn({
        state, history, voice: true, isStale,
        onText: (text) => {
          void stream.writeSSE({ data: chunk(first ? { role: 'assistant', content: text } : { content: text }) });
          first = false;
        },
      });

      if (result.endCall && canEndCall) {
        await stream.writeSSE({ data: chunk({ tool_calls: [{ index: 0, id: `call_${randomUUID()}`, type: 'function', function: { name: 'end_call', arguments: JSON.stringify({ reason: state.outcome ?? 'conversation_finished' }) } }] }) });
        await stream.writeSSE({ data: chunk({}, 'tool_calls') });
      } else {
        await stream.writeSSE({ data: chunk({}, 'stop') });
      }
      await stream.writeSSE({ data: '[DONE]' });
    } catch (err) {
      console.error(`[llm] ${conversationId ?? '?'}: ${(err as Error).message}`);
      await stream.writeSSE({ data: chunk({ role: 'assistant', content: 'Disculpe, ¿me podría repetir, por favor?' }) });
      await stream.writeSSE({ data: chunk({}, 'stop') });
      await stream.writeSSE({ data: '[DONE]' });
    }
  });
}
