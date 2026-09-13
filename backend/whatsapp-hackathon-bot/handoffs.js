// Handoff de voz → WhatsApp (docs/TAREA-CLAUDE-HANDOFF-VOZ-WHATSAPP.md).
//
// Sin plantilla aprobada de Meta, el banco no puede escribir primero: el
// agente de voz le pide al cliente que envíe "CONTINUAR" (o cualquier
// mensaje) al WhatsApp del banco, y ESO abre la ventana de servicio de 24h.
// Este módulo detecta esa entrada, reclama el handoff pendiente de forma
// atómica (claim_handoff) y responde con contenido armado SOLO desde el
// payload que ya validó create_handoff — nunca se le pide a un LLM que
// invente montos, fechas o el recibo.
import { getPendingWhatsAppHandoff, claimHandoff, completeHandoff, startConversation, logMessage } from './supabase.js';
import { sendWhatsAppMessage } from './whatsapp.js';

function money(v) {
  return typeof v === 'number' ? `$${v.toFixed(2)}` : (v ?? 'el monto acordado');
}

// Cada builder recibe SOLO el payload guardado por create_handoff (0700/1500) y devuelve texto plano.
// No hay llamada a Gemini aquí a propósito: el contenido de un handoff debe ser 100% determinista.
const BUILDERS = {
  SEND_PAYMENT_LINK(payload) {
    const cm = payload.commitment;
    const amount = payload.amount_text ?? money(payload.amount ?? cm?.amount);
    const lines = [
      'Aquí tiene el comprobante de su compromiso con Bancoagrícola.',
      cm?.receipt_code ? `Código de confirmación: ${cm.receipt_code}.` : null,
      cm?.terms_text ?? `Pago de ${amount} acordado con nosotros.`,
      payload.payment_url ? `Puede pagar aquí: ${payload.payment_url}` : null,
    ];
    return lines.filter(Boolean).join('\n');
  },
  SEND_COMMITMENT_SUMMARY(payload) {
    const cm = payload.commitment;
    const pending = cm?.status === 'pending_approval';
    const lines = [
      pending
        ? 'Recibimos su solicitud y un asesor la revisará en un máximo de 24 horas hábiles.'
        : 'Este es el resumen de lo que acordamos en su llamada con Bancoagrícola.',
      cm?.receipt_code ? `Código de confirmación: ${cm.receipt_code}.` : null,
      cm?.terms_text ?? null,
    ];
    return lines.filter(Boolean).join('\n');
  },
  SEND_OFFER_DETAILS(payload) {
    const offers = Array.isArray(payload.offers) ? payload.offers : [];
    if (!offers.length) return 'Estas son las opciones que conversamos en su llamada con Bancoagrícola. Un asesor puede confirmarle los detalles si lo necesita.';
    const list = offers.map((o, i) => `${i + 1}. ${o.name ?? o.code}`).join('\n');
    return `Estas son las opciones autorizadas que conversamos en su llamada con Bancoagrícola:\n${list}\n\nResponda con el número de la que le interese y seguimos desde aquí.`;
  },
  FOLLOW_UP_MESSAGE(payload) {
    return payload.context_summary_override
      ?? 'Gracias por escribirnos. Seguimos aquí con su cuota de Bancoagrícola — cuéntenos en qué le podemos ayudar.';
  },
  CALLBACK(payload) {
    const date = payload.date ?? payload.callback_date;
    const window = payload.window ? ` en la ${payload.window}` : '';
    return date
      ? `Quedó agendada su rellamada para el ${date}${window}. Si necesita cambiarla, respóndanos por aquí.`
      : 'Quedó agendada su rellamada. Si necesita cambiarla, respóndanos por aquí.';
  },
};

function buildMessage(action, payload, contextSummary) {
  const builder = BUILDERS[action];
  if (!builder) return contextSummary ?? 'Gracias por escribirnos, seguimos su caso con Bancoagrícola.';
  return builder(payload ?? {});
}

/**
 * Si `customerId` tiene un handoff de WhatsApp pendiente, lo reclama y responde.
 * Devuelve { text } si lo atendió, o null si no había nada pendiente (el
 * llamador debe seguir con el flujo normal del chatbot).
 */
export async function tryConsumePendingHandoff(customerId, phone, inboundText) {
  const handoff = await getPendingWhatsAppHandoff(customerId);
  if (!handoff) return null;

  const claimed = await claimHandoff(handoff.id);
  if (!claimed?.ok) return null;   // otro proceso ya lo tomó (webhook duplicado, dos réplicas del bot)

  let conversationId = null;
  try {
    const started = await startConversation(customerId, 'whatsapp', 'inbound', handoff.from_conversation_id);
    conversationId = started.conversation_id;
    await logMessage(conversationId, 'customer', inboundText);

    const text = buildMessage(handoff.action, handoff.payload, handoff.context_summary);
    await sendWhatsAppMessage(phone, text);
    await logMessage(conversationId, 'agent', text);

    await completeHandoff(handoff.id, conversationId, 'completed');
    return { text };
  } catch (err) {
    const message = err?.message ?? String(err);
    console.error(`Handoff ${handoff.id} falló al entregarse:`, message);
    // Sin secretos en el registro: el mensaje de axios/Meta puede traer headers con el token.
    await completeHandoff(handoff.id, conversationId, 'failed', message.slice(0, 300)).catch(() => null);
    return null;   // el llamador cae al chatbot normal; correo ya quedó como fallback desde finalize.ts
  }
}
