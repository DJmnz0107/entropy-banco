/** Envío de correo con Resend (API REST, sin SDK). */
import { config } from '../config.js';

export interface EmailPayload { to: string; subject: string; html: string; text: string; from: string }

export async function sendWithResend(payload: EmailPayload): Promise<{ id: string }> {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.resend.apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: payload.from, to: [payload.to], subject: payload.subject, html: payload.html, text: payload.text }),
  });
  const body = (await res.json().catch(() => ({}))) as { id?: string; message?: string; name?: string };
  if (!res.ok || !body.id) throw new Error(`Resend ${res.status}: ${body.message ?? body.name ?? 'error desconocido'}`);
  return { id: body.id };
}
