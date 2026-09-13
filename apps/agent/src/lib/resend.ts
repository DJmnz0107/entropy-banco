/** Envío de correo con Resend (API REST, sin SDK). */
import { config } from '../config.js';

/** Imagen incrustada: se referencia en el HTML como src="cid:<contentId>" (no depende de una URL pública). */
export interface InlineImage { filename: string; contentBase64: string; contentId: string }

export interface EmailPayload { to: string; subject: string; html: string; text: string; from: string; inlineImages?: InlineImage[] }

export async function sendWithResend(payload: EmailPayload): Promise<{ id: string }> {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.resend.apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: payload.from, to: [payload.to], subject: payload.subject, html: payload.html, text: payload.text,
      ...(payload.inlineImages?.length
        ? { attachments: payload.inlineImages.map((image) => ({ filename: image.filename, content: image.contentBase64, content_id: image.contentId })) }
        : {}),
    }),
  });
  const body = (await res.json().catch(() => ({}))) as { id?: string; message?: string; name?: string };
  if (!res.ok || !body.id) throw new Error(`Resend ${res.status}: ${body.message ?? body.name ?? 'error desconocido'}`);
  return { id: body.id };
}
