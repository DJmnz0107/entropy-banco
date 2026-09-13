/** ElevenLabs Agents: llamada saliente vía Twilio nativo y verificación de webhooks. */
import { ElevenLabsClient } from '@elevenlabs/elevenlabs-js';
import { config } from '../config.js';

export async function outboundCall(toNumber: string, dynamicVariables: Record<string, string | number | boolean>) {
  const res = await fetch('https://api.elevenlabs.io/v1/convai/twilio/outbound-call', {
    method: 'POST',
    headers: { 'xi-api-key': config.elevenlabs.apiKey ?? '', 'Content-Type': 'application/json' },
    body: JSON.stringify({
      agent_id: config.elevenlabs.agentId,
      agent_phone_number_id: config.elevenlabs.phoneNumberId,
      to_number: toNumber,
      conversation_initiation_client_data: { dynamic_variables: dynamicVariables },
    }),
  });
  const body = (await res.json().catch(() => ({}))) as { success?: boolean; message?: string; conversation_id?: string | null; callSid?: string | null; detail?: unknown };
  if (!res.ok || body.success === false) {
    throw new Error(`ElevenLabs ${res.status}: ${body.message ?? JSON.stringify(body.detail ?? body)}`);
  }
  return { conversationId: body.conversation_id ?? null, callSid: body.callSid ?? null };
}

let client: ElevenLabsClient | null = null;
export async function verifyWebhook(rawBody: string, signature: string | undefined): Promise<Record<string, unknown>> {
  client ??= new ElevenLabsClient({ apiKey: config.elevenlabs.apiKey ?? 'unused' });
  return client.webhooks.constructEvent(rawBody, signature ?? '', config.elevenlabs.webhookSecret ?? '');
}
