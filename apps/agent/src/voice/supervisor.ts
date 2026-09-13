/**
 * Supervisor silencioso: evalúa el último intercambio con los criterios de la etapa
 * (prompt y esquema desde prompt_versions) y el controlador de la BD decide.
 */
import { gemini, modelFor, withRetry } from '../lib/llm.js';
import { db, type Json } from '../lib/supabase.js';
import { stageInfo, type ConversationState } from './state.js';

const TIMEOUT_MS = 6000;

export async function evaluateExchange(state: ConversationState, agentText: string | null, customerText: string, messageId: string | undefined): Promise<void> {
  const stage = stageInfo(state);
  const [prompt, model, criteria] = await Promise.all([
    db.prompt('supervisor.scorecard'),
    modelFor('supervisor'),
    db.criteria(stage?.criteria ?? []),
  ]);
  if (!prompt) return;

  const content = prompt.content
    .replace('{etapa_nombre}', stage?.name ?? state.stage)
    .replace('{etapa_objetivo}', stage?.objective ?? '')
    .replace('{criterios}', criteria.map((c) => `- ${c.key}: ${c.description}`).join('\n'))
    .replace('{transcripcion_reciente}', `Agente: ${agentText ?? '(inicio de la llamada)'}\nCliente: ${customerText}`);

  const started = Date.now();
  let scorecard: Json;
  try {
    const res = await withRetry(() => gemini.chat.completions.create({
      model: model.modelId,
      temperature: 0,
      max_tokens: model.maxTokens,
      messages: [{ role: 'user', content }],
      response_format: prompt.output_schema
        ? { type: 'json_schema', json_schema: { name: 'scorecard', schema: prompt.output_schema as Record<string, unknown>, strict: true } }
        : { type: 'json_object' },
    }, { timeout: TIMEOUT_MS }));
    scorecard = JSON.parse(res.choices[0]?.message?.content ?? '{}') as Json;
  } catch (err) {
    console.warn(`[supervisor] sin evaluación este turno: ${(err as Error).message}`);
    return;
  }

  const ev = await db.evaluateTurn(state.conversationId, scorecard, messageId, {
    evaluator_model_key: model.key, latency_ms: Date.now() - started,
  });
  if (ev.decision === 'ignored') return;

  state.stage = ev.to_stage;
  state.pace = ev.pace;
  state.pendingControl = ev.control_message;
  if (ev.is_terminal) {
    state.endCall = true;
    state.outcome = state.outcome ?? ev.suggested_outcome;
  }
}
