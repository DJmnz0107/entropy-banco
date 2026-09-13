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

/** Override por variable de entorno (útil para repartir cuota del free tier entre modelos: el límite es por modelo). */
const ENV_OVERRIDE: Record<string, string | undefined> = {
  composer: process.env.COMPOSER_MODEL,
  supervisor: process.env.SUPERVISOR_MODEL,
  customer_simulator: process.env.SIMULATOR_MODEL,
};

/** role: composer | supervisor | customer_simulator — env > agent_policies.default_models > fallback. */
export async function modelFor(role: 'composer' | 'supervisor' | 'customer_simulator'): Promise<Profile & { key: string }> {
  const override = ENV_OVERRIDE[role]?.trim();
  if (override) return { key: `env.${role}`, ...FALLBACKS[role], modelId: override };
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

/** Reintento ante 429/503 respetando el "retry in Xs" que devuelve Gemini (máx. 8 s por espera). */
export async function withRetry<T>(fn: () => Promise<T>, attempts = 3): Promise<T> {
  let lastError: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const status = (err as { status?: number }).status;
      if (status !== 429 && status !== 503) throw err;
      const hinted = /retry in ([\d.]+)s/i.exec(String((err as Error).message))?.[1];
      const waitMs = Math.min(8000, hinted ? Math.ceil(Number(hinted) * 1000) + 250 : 1000 * (i + 1));
      console.warn(`[llm] ${status}: reintento en ${waitMs} ms`);
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }
  throw lastError;
}

/**
 * Voz: ante 503 "high demand", 429 o timeout NO se espera: se pasa al siguiente modelo de la cadena.
 * Con el free tier de Gemini los picos de demanda cortaban llamadas enteras (13-sept).
 * Cadena: modelo del perfil → COMPOSER_FALLBACK_MODELS (coma) → reintento con espera del primero.
 */
export async function withModelFallback<T>(primary: string, fn: (modelId: string) => Promise<T>): Promise<T> {
  const chain = [primary, ...(process.env.COMPOSER_FALLBACK_MODELS ?? 'gemini-3.5-flash-lite,gemini-3-flash-preview')
    .split(',').map((m) => m.trim()).filter((m) => m && m !== primary)];
  let lastError: unknown;
  for (const modelId of chain) {
    try {
      return await fn(modelId);
    } catch (err) {
      lastError = err;
      const status = (err as { status?: number }).status;
      const timeout = (err as Error).name === 'APIConnectionTimeoutError' || /timed out/i.test(String((err as Error).message));
      if (status !== 429 && status !== 503 && !timeout) throw err;
      console.warn(`[llm] ${modelId} ${status ?? 'timeout'}: paso al siguiente modelo`);
    }
  }
  return withRetry(() => fn(primary), 2).catch(() => { throw lastError; });
}
