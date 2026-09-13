import type { Context, Next } from 'hono';
import { config } from '../config.js';

/** Protege endpoints que disparan acciones (corridas, llamadas, reset). */
export async function requireAgentSecret(c: Context, next: Next) {
  if (!config.agentSharedSecret) {
    console.warn('[auth] AGENT_SHARED_SECRET no configurado: endpoint abierto (solo desarrollo)');
    return next();
  }
  if (c.req.header('x-agent-secret') !== config.agentSharedSecret) return c.json({ error: 'No autorizado' }, 401);
  return next();
}
