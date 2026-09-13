/**
 * Correos de la corrida:
 *   reminder     → grados A–B (recordatorio preventivo + video)
 *   fallback     → grados C–E que no se pudieron llamar o no contestaron
 *   confirmation → después de un compromiso en la llamada
 * Real solo si hay RESEND_API_KEY, el cliente tiene contact_enabled y un correo válido. Si no, se simula (queda registrado).
 */
import { config, providers } from '../config.js';
import { sendWithResend } from '../lib/resend.js';
import { emailImages, renderBankEmail, type BankEmail, type EmailDetail, type EmailVideo } from './email-template.js';
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

/** Fecha de negocio (YYYY-MM-DD) sin corrimiento de zona: "14 de septiembre de 2026". */
function dateText(isoDate: string | null | undefined): string | null {
  if (!isoDate || !/^\d{4}-\d{2}-\d{2}/.test(isoDate)) return null;
  return new Intl.DateTimeFormat('es-SV', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${isoDate.slice(0, 10)}T00:00:00Z`));
}

/** Fecha y hora del registro en El Salvador: "13/09/2026 15:43". */
function nowText(): string {
  return new Intl.DateTimeFormat('es-SV', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'America/El_Salvador' }).format(new Date());
}

function videoFrom(v: { ok: boolean; url?: string; title?: string; duration_s?: number } | null): EmailVideo {
  return v?.ok && v.url ? { title: v.title ?? 'Educación financiera', url: publicUrl(v.url)!, duration: v.duration_s ?? 20 } : null;
}

/** Condiciones con variables sin reemplazar ("{monto}") no se envían al cliente como acuerdo. */
function resolvedTerms(terms: string | null | undefined): string | null {
  return terms && !/\{[a-z_]+\}/i.test(terms) ? terms : null;
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
    const amount = link?.amount_text ?? item.amount_due_text;
    const due = dateText(item.due_date) ?? item.due_date_text ?? 'su próxima fecha de pago';
    const details: EmailDetail[] = [
      ['Producto', item.product_name ?? 'Crédito'],
      ['Monto de la cuota', amount],
      ['Fecha de vencimiento', due],
      ['Referencia del cliente', item.customer_code],
    ];

    const email: BankEmail = kind === 'reminder'
      ? {
          customerName: item.full_name,
          intro: ['Por este medio le recordamos que su próxima cuota está por vencer. Pagar a tiempo le ayuda a mantener su buen récord crediticio.'],
          detailsTitle: 'Datos de su cuota:',
          details,
          closing: ['Puede pagar desde su celular con el enlace seguro. Si prevé alguna dificultad para pagar, contáctenos antes del vencimiento y buscaremos juntos una opción.'],
          button: payUrl ? { label: 'Pagar mi cuota', url: payUrl } : null,
          video: videoFrom(video),
        }
      : {
          customerName: item.full_name,
          intro: ['Por este medio le informamos que intentamos comunicarnos con usted por teléfono para acompañarle con su próxima cuota.'],
          detailsTitle: 'Datos de su cuota:',
          details,
          closing: [
            item.offers.length
              ? `Si este mes se le complica, tenemos opciones autorizadas para usted: ${item.offers.map((o) => o.name.toLowerCase()).join('; ')}.`
              : 'Si este mes se le complica, contáctenos y buscaremos juntos una opción.',
            'Queremos ayudarle antes de que se genere un atraso.',
          ],
          button: payUrl ? { label: 'Pagar mi cuota', url: payUrl } : null,
          video: videoFrom(video),
        };
    const subject = kind === 'reminder'
      ? `Recordatorio de pago: su cuota de ${amount} vence el ${due}`
      : 'Intentamos comunicarnos con usted · Banco Agrícola';
    const { html, text } = renderBankEmail(email);

    let providerId: string | null = null;
    if (real) providerId = (await sendWithResend({ to: item.email!, subject, html, text, from: await fromAddress(), inlineImages: emailImages() })).id;

    await db.logMessage(conversationId, 'agent', `Asunto: ${subject}\n\n${text}`, {
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
    const pendingApproval = state.commitment.requiresApproval;
    const subject = pendingApproval
      ? `Recibimos su solicitud ${state.commitment.receipt} · Banco Agrícola`
      : `Confirmación de su compromiso de pago ${state.commitment.receipt} · Banco Agrícola`;

    const details: EmailDetail[] = [['Código de confirmación', state.commitment.receipt]];
    const terms = resolvedTerms(commitment?.terms_text);
    if (terms) details.push(['Acuerdo', terms]);
    if (commitment?.amount != null) details.push(['Monto', link?.amount_text ?? `$${commitment.amount.toFixed(2)}`]);
    const committed = dateText(commitment?.committed_date);
    if (committed) details.push(['Fecha comprometida', committed]);
    details.push(['Estado', pendingApproval ? 'Pendiente de aprobación' : 'Registrado'], ['Fecha y hora de registro', nowText()]);

    const { html, text } = renderBankEmail({
      customerName: contact.full_name,
      intro: [pendingApproval
        ? 'Por este medio le informamos que recibimos su solicitud de acuerdo de pago. Un asesor la revisará en un máximo de 24 horas hábiles.'
        : 'Por este medio le confirmamos el registro de su compromiso de pago. Gracias por conversar con nosotros.'],
      detailsTitle: pendingApproval ? 'Datos de la solicitud:' : 'Datos del compromiso:',
      details,
      closing: pendingApproval ? [] : ['Conserve este código de confirmación para cualquier consulta.'],
      button: payUrl ? { label: 'Pagar ahora', url: payUrl } : null,
      video: videoFrom(video),
    });

    let providerId: string | null = null;
    if (real) providerId = (await sendWithResend({ to: contact.email!, subject, html, text, from: await fromAddress(), inlineImages: emailImages() })).id;
    await db.logMessage(state.conversationId, 'system', `Correo de confirmación ${real ? 'enviado' : 'simulado'} · Asunto: ${subject}`, {
      input_modality: 'text', channel: 'email', provider: real ? 'resend' : 'simulated', provider_id: providerId,
    });
    await db.syncPlanStep(state.interventionId, 'CONFIRMATION', 'done', state.conversationId, { provider: real ? 'resend' : 'simulated' });
  } catch (err) {
    console.warn(`[email] confirmación ${state.conversationId}: ${(err as Error).message}`);
    await db.syncPlanStep(state.interventionId, 'CONFIRMATION', 'failed', state.conversationId, { error: (err as Error).message }).catch(() => null);
  }
}

/** Datos para el correo preventivo de UN cliente (botón "Enviar correo" de la web), fuera de una corrida. */
export async function reminderItemForCustomer(customerId: string): Promise<RunIntervention | null> {
  const [contact, ctx, intervention] = await Promise.all([db.customerContact(customerId), db.context(customerId), db.interventionForCustomer(customerId)]);
  if (!contact) return null;
  const nb = (intervention?.next_best ?? {}) as {
    why?: string[]; offers?: Array<{ code: string; name: string }>;
    education?: { slug: string; title: string; duration_s: number } | null;
  };
  const loan = ctx.loan;
  return {
    intervention_id: intervention?.id ?? '', customer_id: customerId, customer_code: contact.customer_code,
    full_name: contact.full_name, first_name: contact.first_name, phone_e164: contact.phone_e164, email: contact.email,
    contact_enabled: contact.contact_enabled, grade: intervention?.grade ?? '', action: 'EMAIL_REMINDER', channel: 'email', priority: 0,
    amount_at_risk: loan?.amount_due ?? 0, amount_due_text: loan?.amount_due_text ?? '', due_date: loan?.next_due_date ?? null,
    due_date_text: loan?.next_due_date_text ?? null, product_name: loan?.product_name ?? null,
    why: nb.why ?? [], offers: nb.offers ?? ctx.offers.slice(0, 3).map((o) => ({ code: o.code, name: o.name })),
    education: nb.education ?? null,
  };
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
