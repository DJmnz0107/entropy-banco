/**
 * Llamada SIMULADA: el mismo motor de turnos que ElevenLabs, pero el cliente lo interpreta Gemini
 * (o un guion de apps/agent/scenarios). Escribe todo en Supabase en tiempo real, así la web
 * muestra la "Intervención en vivo" sin teléfono ni ElevenLabs. Queda marcada como sintética.
 */
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { gemini, modelFor, withRetry } from '../lib/llm.js';
import { db } from '../lib/supabase.js';
import { getState } from '../voice/state.js';
import { runAgentTurn, type HistoryMessage } from '../voice/turn.js';
import { finalizeConversation } from './finalize.js';

export interface Scenario {
  key: string;
  customer_code: string;
  description?: string;
  turns: Array<{ customer: string; interrupt_previous_agent_at?: number }>;
  expect?: {
    outcome_in?: string[];
    commitment?: boolean;
    must_reach_stages?: string[];
    must_not_say?: string[];
    must_have_events?: string[];
    max_same_offer_validations?: number;
    db_must_not_contain?: string[];
  };
}

const scenariosDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scenarios');

export async function loadScenario(key: string): Promise<Scenario> {
  return JSON.parse(await fs.readFile(path.join(scenariosDir, `${key}.json`), 'utf8')) as Scenario;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function simulateCustomer(persona: string, history: HistoryMessage[]): Promise<string> {
  const [prompt, model] = await Promise.all([db.prompt('simulator.customer'), modelFor('customer_simulator')]);
  const system = (prompt?.content ?? 'Actúas como un cliente salvadoreño recibiendo una llamada de su banco. Persona: {persona}')
    .replace('{persona}', persona).replace('{plan_interrupciones}', 'Ninguno.');
  const res = await withRetry(() => gemini.chat.completions.create({
    model: model.modelId,
    temperature: model.temperature,
    max_tokens: model.maxTokens,
    messages: [
      { role: 'system', content: `${system}\nResponde en 1 o 2 frases cortas, como hablarías por teléfono. Si la conversación terminó, despídete.` },
      // roles invertidos: el agente es "user" para el simulador
      ...history.map((m) => ({ role: m.role === 'assistant' ? 'user' as const : 'assistant' as const, content: m.content })),
    ],
  }));
  return (res.choices[0]?.message?.content ?? '').trim();
}

function personaFor(ctx: Awaited<ReturnType<typeof db.context>>, grade: string | null): string {
  const mood = grade === 'E' ? 'preocupado y algo a la defensiva, pero dispuesto a escuchar'
    : grade === 'D' ? 'con dificultad temporal para pagar completo; si le ofrecen una alternativa razonable, la acepta'
    : 'cooperativo; puede pagar pero agradece un recordatorio o una fecha un poco después';
  const signals = ctx.signals.map((s) => s.detail).slice(0, 2).join('; ');
  return `${ctx.customer.full_name}, ${ctx.customer.occupation ?? 'cliente del banco'}. Tiene una cuota de ${ctx.loan?.amount_due_text ?? 'su crédito'} que vence el ${ctx.loan?.next_due_date_text ?? 'pronto'}. Está ${mood}.${signals ? ` Contexto real: ${signals}.` : ''} Confirma que es el titular cuando se lo pregunten.`;
}

export async function runSimulatedCall(customerId: string, interventionId: string | null, scenario?: Scenario, opts: { pacingMs?: number; maxTurns?: number } = {}): Promise<{ conversationId: string; outcome: string; transcript: HistoryMessage[] }> {
  const start = await db.startSimulated(customerId, 'voice', interventionId);
  const conversationId = start.conversation_id;
  const state = await getState(conversationId);
  const intervention = interventionId ? await db.interventionById(interventionId) : null;
  const persona = personaFor(state.context, intervention?.grade ?? (state.nextBest as { grade?: string } | null)?.grade ?? null);

  const history: HistoryMessage[] = [];
  const maxTurns = opts.maxTurns ?? (scenario ? scenario.turns.length : 9);
  let silences = 0;
  let answered = false;

  let failure: string | null = null;
  try {
  for (let i = 0; i < maxTurns; i++) {
    if (state.hangupRequested) break;
    const step = scenario?.turns[i];
    let customerText = step ? step.customer : (i === 0 ? '¿Aló?' : await simulateCustomer(persona, history));

    // interrupción: el agente solo alcanzó a decir una parte del mensaje anterior
    if (step?.interrupt_previous_agent_at && history.at(-1)?.role === 'assistant') {
      const last = history.at(-1)!;
      last.content = last.content.slice(0, Math.max(10, Math.floor(last.content.length * step.interrupt_previous_agent_at)));
    }

    if (!customerText) {
      silences += 1;
      if (silences > 2) break;
      customerText = '...';
    } else {
      answered = true;
    }

    history.push({ role: 'user', content: customerText });
    const turn = await runAgentTurn({ state, history, voice: true });
    history.push({ role: 'assistant', content: turn.text });
    if (turn.endCall || state.hangupRequested) break;
    await sleep(opts.pacingMs ?? 2500);   // ritmo visible en la vista en vivo y alivia la cuota de Gemini
  }
  } catch (err) {
    failure = (err as Error).message;
    console.warn(`[simulada] ${conversationId} falló: ${failure}`);
  }

  // Nunca dejar una conversación colgada: si falló a mitad, se cierra (con compromiso si alcanzó a registrarlo)
  if (failure && !state.commitment) {
    await db.endConversation(conversationId, 'FAILED', `Llamada simulada interrumpida: ${failure.slice(0, 180)}`).catch(() => null);
    return { conversationId, outcome: 'FAILED', transcript: history };
  }
  const { outcome } = await finalizeConversation(conversationId, { answered, realCall: false, summary: `Llamada simulada${scenario ? ` (${scenario.key})` : ''}${failure ? ' (interrumpida)' : ''}.` });
  return { conversationId, outcome, transcript: history };
}
