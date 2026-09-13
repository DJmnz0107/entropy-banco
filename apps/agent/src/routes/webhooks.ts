/**
 * POST /webhooks/elevenlabs — post_call_transcription · call_initiation_failure (firma HMAC con el SDK oficial).
 */
import { Hono } from 'hono';
import { config } from '../config.js';
import { verifyWebhook } from '../lib/elevenlabs.js';
import { db } from '../lib/supabase.js';
import { finalizeConversation } from '../channels/finalize.js';

export const webhooksRouter = new Hono();

type WebhookEvent = {
  type?: string;
  data?: {
    conversation_id?: string;
    transcript?: Array<{ role: string; message?: string | null }>;
    metadata?: { call_duration_secs?: number };
    analysis?: { transcript_summary?: string; call_successful?: string };
    conversation_initiation_client_data?: { dynamic_variables?: Record<string, unknown> };
    failure_reason?: string;
  };
};

webhooksRouter.post('/webhooks/elevenlabs', async (c) => {
  const raw = await c.req.text();
  let event: WebhookEvent;
  try {
    if (config.elevenlabs.webhookSecret) {
      event = (await verifyWebhook(raw, c.req.header('elevenlabs-signature'))) as WebhookEvent;
    } else if (config.customLlmSecret && c.req.header('x-simulator-secret') === config.customLlmSecret) {
      event = JSON.parse(raw) as WebhookEvent;   // pruebas locales
    } else {
      return c.json({ error: 'Webhook sin verificar: configura ELEVENLABS_WEBHOOK_SECRET' }, 401);
    }
  } catch (err) {
    return c.json({ error: `Firma inválida: ${(err as Error).message}` }, 401);
  }

  const data = event.data ?? {};
  const conversationId = (data.conversation_initiation_client_data?.dynamic_variables?.conversation_id as string | undefined)
    ?? (data.conversation_id ? await db.conversationByExternalId(data.conversation_id) : null);
  if (!conversationId) return c.json({ ok: true, ignored: 'conversación desconocida' });

  try {
    if (data.conversation_id) await db.setExternalId(conversationId, data.conversation_id).catch(() => null);
    if (event.type === 'call_initiation_failure') {
      const r = await finalizeConversation(conversationId, { answered: false, realCall: true, failureReason: data.failure_reason ?? 'no contestó' });
      return c.json({ ok: true, ...r });
    }
    if (event.type === 'post_call_transcription') {
      const answered = (data.transcript ?? []).some((t) => t.role === 'user' && (t.message ?? '').trim() !== '');
      const r = await finalizeConversation(conversationId, {
        answered, realCall: true, durationSecs: data.metadata?.call_duration_secs ?? null, summary: data.analysis?.transcript_summary ?? null,
      });
      return c.json({ ok: true, ...r });
    }
    return c.json({ ok: true, ignored: event.type });
  } catch (err) {
    console.error(`[webhook] ${conversationId}: ${(err as Error).message}`);
    return c.json({ ok: false, error: (err as Error).message }, 500);
  }
});
