/**
 * Gemini vía su endpoint compatible con OpenAI. Los modelos se leen de ai_model_profiles
 * (cambiar de modelo = editar una fila), con caché corta.
 */
import OpenAI from 'openai';
import { config } from '../config.js';
import { db } from './supabase.js';

// Sin reintentos del SDK (se duplicaban con withRetry) y tope de 12 s: en una llamada es mejor pedir que repita que quedarse mudo.
export const gemini = new OpenAI({ apiKey: config.geminiApiKey ?? 'missing', baseURL: config.geminiBaseUrl, maxRetries: 0, timeout: 12_000 });

type Profile = { modelId: string; temperature: number; maxTokens: number };
/** Modelos que Google ya no ofrece a cuentas nuevas (verificado 12/09/2026). */
const RETIRED = new Set(['gemini-2.5-flash-lite', 'gemini-2.0-flash-lite', 'gemini-2.0-flash']);
const cache = new Map<string, { at: number; profile: Profile }>();

const FALLBACKS: Record<string, Profile> = {
  composer: { modelId: 'gemini-3.1-flash-lite', temperature: 0.3, maxTokens: 220 },
  supervisor: { modelId: 'gemini-3.1-flash-lite', temperature: 0, maxTokens: 600 },
  customer_simulator: { modelId: 'gemini-3.1-flash-lite', temperature: 0.9, maxTokens: 120 },
};

/** role: composer | supervisor | customer_simulator — resuelve por agent_policies.default_models o clave fija. */
export async function modelFor(role: 'composer' | 'supervisor' | 'customer_simulator'): Promise<Profile & { key: string }> {
  const hit = cache.get(role);
  if (hit && Date.now() - hit.at < 60_000) return { key: role, ...hit.profile };
  let key = role === 'customer_simulator' ? 'simulator.gemini-3.1-flash-lite' : undefined;
  if (!key) {
    const policy = await db.activePolicy().catch(() => null);
    key = policy?.default_models?.[role];
  }
  const row = key ? await db.modelProfile(key).catch(() => null) : null;
  const params = (row?.params ?? {}) as { temperature?: number; max_output_tokens?: number };
  if (row && RETIRED.has(row.model_id)) row.model_id = FALLBACKS[role].modelId;
  const profile: Profile = row?.provider === 'google'
    ? { modelId: row.model_id, temperature: params.temperature ?? FALLBACKS[role].temperature, maxTokens: params.max_output_tokens ?? FALLBACKS[role].maxTokens }
    : FALLBACKS[role];
  cache.set(role, { at: Date.now(), profile });
  return { key: row?.key ?? `fallback.${role}`, ...profile };
}

/** Reintento simple ante límites de tasa del free tier. */
export async function withRetry<T>(fn: () => Promise<T>, attempts = 2): Promise<T> {
  let lastError: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const status = (err as { status?: number }).status;
      if (status !== 429 && status !== 503) throw err;
      await new Promise((r) => setTimeout(r, 800 * (i + 1)));
    }
  }
  throw lastError;
}
