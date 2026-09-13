/**
 * Correos de la corrida:
 *   reminder     → grados A–B (recordatorio preventivo + video)
 *   fallback     → grados C–E que no se pudieron llamar o no contestaron
 *   confirmation → después de un compromiso en la llamada
 * Real solo si hay RESEND_API_KEY, el cliente tiene contact_enabled y un correo válido. Si no, se simula (queda registrado).
 */
import { config, providers } from '../config.js';
import { sendWithResend } from '../lib/resend.js';
import { db, type RunIntervention } from '../lib/supabase.js';
import type { ConversationState } from '../voice/state.js';

export type EmailKind = 'reminder' | 'fallback';

function publicUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  return url.replace(/^https?:\/\/[^/]+/, config.publicWebUrl);
}

function canSendReal(contactEnabled: boolean, email: string | null): email is string {
  return providers.email() === 'resend' && contactEnabled && !!email && !/\.test$|\.invalid$|example\.com$/i.test(email);
}

async function fromAddress(): Promise<string> {
  if (config.resend.from) return config.resend.from;
  const policy = await db.activePolicy().catch(() => null);
  return policy?.email_from ?? 'Bancoagrícola Demo <onboarding@resend.dev>';
}

type Button = { label: string; url: string } | null;
type Video = { title: string; url: string; duration: number } | null;

function layout(title: string, paragraphs: string[], button: Button, video: Video): string {
  const p = paragraphs.map((t) => `<p style="margin:0 0 14px;line-height:1.55">${t}</p>`).join('');
  const btn = button
    ? `<p style="margin:22px 0"><a href="${button.url}" style="background:#1f7a4d;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600">${button.label}</a></p>`
    : '';
  const vid = video
    ? `<div style="margin:22px 0;padding:14px 16px;background:#f4f7f2;border-radius:10px"><strong>🎬 ${video.title}</strong> · ${video.duration} s<br/><a href="${video.url}" style="color:#1f7a4d">Ver el video</a></div>`
    : '';
  return `<div style="font-family:Arial,Helvetica,sans-serif;color:#1d1d1b;max-width:560px;margin:auto;padding:24px">
<h2 style="margin:0 0 18px;font-size:20px">${title}</h2>${p}${btn}${vid}
<p style="margin-top:28px;font-size:12px;color:#777">Mensaje de demostración · Entropía Hack 2026 · datos ficticios. Si no desea recibir estos mensajes, responda "BAJA".</p></div>`;
}

function toText(title: string, paragraphs: string[], button: Button, video: Video): string {
  const plain = paragraphs.map((t) => t.replace(/<[^>]+>/g, ''));
  return [
    title, '', ...plain,
    button ? `\n${button.label}: ${button.url}` : '',
    video ? `\nVideo: ${video.title} — ${video.url}` : '',
    '\nMensaje de demostración · datos ficticios.',
  ].join('\n');
}

function videoFrom(v: { ok: boolean; url?: string; title?: string; duration_s?: number } | null): Video {
  return v?.ok && v.url ? { title: v.title ?? 'Educación financiera', url: publicUrl(v.url)!, duration: v.duration_s ?? 20 } : null;
}

/** Crea la conversación de correo, arma el mensaje, lo envía (o simula) y cierra con MESSAGE_SENT. */
export async function sendRunEmail(item: RunIntervention, kind: EmailKind): Promise<{ conversationId: string | null; real: boolean; error?: string }> {
  const real = canSendReal(item.contact_enabled, item.email);
  let conversationId: string | null = null;
  try {
    const start = real
      ? await db.startConversation(item.customer_id, 'email', item.intervention_id || null)
      : await db.startSimulated(item.customer_id, 'email', item.intervention_id || null);
    conversationId = start.conversation_id;

    const [link, video] = await Promise.all([
      db.createPaymentLink(conversationId).catch(() => null),
      db.sendEducation(item.customer_id, conversationId, 'email', item.education?.slug).catch(() => null),
    ]);
    const payUrl = publicUrl(link?.url);
    const videoInfo = videoFrom(video);
    const amount = link?.amount_text ?? item.amount_due_text;
    const due = item.due_date_text ?? 'su próxima fecha de pago';

    const content = kind === 'reminder'
      ? {
          subject: `${item.first_name}, su cuota de ${amount} vence el ${due}`,
          paragraphs: [
            `Le escribimos con anticipación para ayudarle a mantener su buen récord crediticio: su cuota de <strong>${amount}</strong> de ${item.product_name ?? 'su crédito'} vence el <strong>${due}</strong>.`,
            'Puede pagar desde su celular con un link seguro. Si prevé alguna dificultad, respóndanos antes del vencimiento y buscamos juntos una opción.',
          ],
        }
      : {
          subject: `${item.first_name}, intentamos comunicarnos con usted`,
          paragraphs: [
            `Hoy intentamos llamarle para acompañarle con su cuota de <strong>${amount}</strong>, que vence el <strong>${due}</strong>.`,
            item.offers.length
              ? `Si este mes se le complica, tenemos opciones autorizadas para usted: ${item.offers.map((o) => o.name.toLowerCase()).join('; ')}.`
              : 'Si este mes se le complica, respóndanos y buscamos juntos una opción.',
            'Queremos ayudarle antes de que se genere un atraso.',
          ],
        };
    const title = `Hola, ${item.first_name}`;
    const button: Button = payUrl ? { label: 'Pagar mi cuota', url: payUrl } : null;
    const html = layout(title, content.paragraphs, button, videoInfo);
    const text = toText(title, content.paragraphs, button, videoInfo);

    let providerId: string | null = null;
    if (real) providerId = (await sendWithResend({ to: item.email!, subject: content.subject, html, text, from: await fromAddress() })).id;

    await db.logMessage(conversationId, 'agent', `Asunto: ${content.subject}\n\n${text}`, {
      input_modality: 'text', channel: 'email', email_kind: kind, provider: real ? 'resend' : 'simulated',
      provider_id: providerId, to: real ? item.email : null,
    });
    await db.endConversation(conversationId, 'MESSAGE_SENT',
      `Correo ${kind === 'reminder' ? 'preventivo' : 'de seguimiento'} ${real ? 'enviado' : 'simulado'}.`);
    return { conversationId, real };
  } catch (err) {
    const message = (err as Error).message;
    console.warn(`[email] ${item.customer_code} (${kind}): ${message}`);
    if (conversationId) await db.endConversation(conversationId, 'FAILED', message).catch(() => null);
    return { conversationId, real, error: message };
  }
}

/** Confirmación post-compromiso. Se registra en la conversación de voz: el compromiso vigente bloquea abrir otra. */
export async function sendConfirmationEmail(state: ConversationState): Promise<void> {
  if (!state.commitment || state.confirmationEmailSent) return;
  state.confirmationEmailSent = true;
  const contact = await db.customerContact(state.customerId);
  if (!contact) return;
  const real = canSendReal(contact.contact_enabled, contact.email);
  try {
    const row = await db.conversationRow(state.conversationId);
    const commitment = row?.commitment_id ? await db.commitment(row.commitment_id) : null;
    const wantsLink = !state.commitment.requiresApproval && (state.commitment.generatesPaymentLink || (commitment?.amount ?? 0) > 0);
    const link = wantsLink ? await db.createPaymentLink(state.conversationId).catch(() => null) : null;
    const video = await db.sendEducation(state.customerId, state.conversationId, 'email').catch(() => null);
    const payUrl = publicUrl(link?.url);
    const subject = state.commitment.requiresApproval
      ? `${contact.first_name}, recibimos su solicitud ${state.commitment.receipt}`
      : `${contact.first_name}, su compromiso ${state.commitment.receipt} quedó registrado`;
    const paragraphs = [
      state.commitment.requiresApproval
        ? 'Gracias por conversar con nosotros. Su solicitud quedó registrada y un asesor la revisará en un máximo de 24 horas hábiles.'
        : 'Gracias por conversar con nosotros. Este es el resumen de lo acordado:',
      `<strong>${commitment?.terms_text ?? 'Compromiso de pago registrado.'}</strong>`,
      `Código de confirmación: ${state.commitment.receipt}.`,
    ];
    const title = `Hola, ${contact.first_name}`;
    const button: Button = payUrl ? { label: 'Pagar ahora', url: payUrl } : null;
    const videoInfo = videoFrom(video);
    const html = layout(title, paragraphs, button, videoInfo);
    const text = toText(title, paragraphs, button, videoInfo);

    let providerId: string | null = null;
    if (real) providerId = (await sendWithResend({ to: contact.email!, subject, html, text, from: await fromAddress() })).id;
    await db.logMessage(state.conversationId, 'system', `Correo de confirmación ${real ? 'enviado' : 'simulado'} · Asunto: ${subject}`, {
      input_modality: 'text', channel: 'email', provider: real ? 'resend' : 'simulated', provider_id: providerId,
    });
    await db.syncPlanStep(state.interventionId, 'CONFIRMATION', 'done', state.conversationId, { provider: real ? 'resend' : 'simulated' });
  } catch (err) {
    console.warn(`[email] confirmación ${state.conversationId}: ${(err as Error).message}`);
    await db.syncPlanStep(state.interventionId, 'CONFIRMATION', 'failed', state.conversationId, { error: (err as Error).message }).catch(() => null);
  }
}

/** Datos para el correo de seguimiento a partir de una llamada que no se completó. */
export async function fallbackItemFromState(state: ConversationState): Promise<RunIntervention | null> {
  const contact = await db.customerContact(state.customerId);
  if (!contact) return null;
  const nb = (state.nextBest ?? {}) as {
    grade?: string; why?: string[];
    offers?: Array<{ code: string; name: string }>;
    education?: { slug: string; title: string; duration_s: number } | null;
  };
  const loan = state.context.loan;
  return {
    intervention_id: state.interventionId ?? '', customer_id: state.customerId, customer_code: contact.customer_code,
    full_name: contact.full_name, first_name: contact.first_name, phone_e164: contact.phone_e164, email: contact.email,
    contact_enabled: contact.contact_enabled, grade: nb.grade ?? '', action: 'EMAIL_FALLBACK', channel: 'email', priority: 0,
    amount_at_risk: loan?.amount_due ?? 0, amount_due_text: loan?.amount_due_text ?? '', due_date: loan?.next_due_date ?? null,
    due_date_text: loan?.next_due_date_text ?? null, product_name: loan?.product_name ?? null,
    why: nb.why ?? [], offers: nb.offers ?? state.context.offers.slice(0, 3).map((o) => ({ code: o.code, name: o.name })),
    education: nb.education ?? null,
  };
}
