/**
 * Herramientas del agente (formato OpenAI). Se ejecutan en NUESTRO servidor contra Supabase:
 * el modelo propone, la BD autoriza. Las fechas las resuelve el código, nunca el LLM.
 */
import type { ChatCompletionTool } from 'openai/resources/chat/completions';
import { db, type Json } from '../lib/supabase.js';
import { sendConfirmationEmail } from '../channels/email.js';
import { resolveSpanishDate } from './dates.js';
import type { ConversationState } from './state.js';

const ERROR_TEXT: Record<string, string> = {
  OFERTA_NO_PERMITIDA_PARA_ESTE_CLIENTE: 'Esa opción no está autorizada para este cliente.',
  NUEVA_FECHA_REQUERIDA: 'Falta la nueva fecha: pregúntale qué día concreto.',
  FECHA_EN_EL_PASADO: 'La fecha ya pasó.',
  DIA_NO_PERMITIDO: 'Ese día no está permitido (domingo): propón otro.',
  CONFIRMACION_EXPLICITA_REQUERIDA: 'Falta un sí explícito del cliente a un resumen.',
  CONDICIONES_NO_PRESENTADAS: 'Primero valida la oferta y di las condiciones.',
  CONDICIONES_INTERRUMPIDAS: 'El cliente no escuchó completas las condiciones: repítelas y vuelve a pedir confirmación.',
};
const humanError = (code: string) =>
  ERROR_TEXT[code] ?? (code.startsWith('EXCEDE_MAXIMO_DE_DIAS_') ? `La fecha excede el máximo permitido de ${code.split('_').pop()} días.` : code.replaceAll('_', ' ').toLowerCase());

const FAREWELLS: Record<string, string> = {
  acuerdo_completo: 'Muchas gracias por su tiempo. Que tenga un excelente día.',
  negativa: 'Entiendo y respeto su decisión. Gracias por atenderme, que tenga un buen día.',
  no_contactar: 'Entendido, registramos su solicitud y no le volveremos a contactar por este medio. Que tenga un buen día.',
  persona_equivocada: 'Muchas gracias por atenderme. Intentaremos comunicarnos en otro momento. Que tenga un buen día.',
  no_es_buen_momento: 'Con gusto le llamamos en otro momento. Que tenga un buen día.',
  otro: 'Muchas gracias por su tiempo. Que tenga un buen día.',
};

const FINAL_OUTCOME: Record<string, string> = {
  acuerdo_completo: 'FOLLOW_UP_REQUIRED', negativa: 'EXPLICIT_REFUSAL', no_contactar: 'DO_NOT_CONTACT',
  persona_equivocada: 'WRONG_PERSON', no_es_buen_momento: 'CALLBACK_SCHEDULED', otro: 'FOLLOW_UP_REQUIRED',
};

export function toolDefinitions(state: ConversationState): ChatCompletionTool[] {
  const codes = state.context.offers.map((o) => o.code);
  const tools: ChatCompletionTool[] = [];
  if (codes.length) {
    tools.push(
      {
        type: 'function',
        function: {
          name: 'validar_oferta',
          description: 'Valida una opción permitida ANTES de decir montos, fechas o condiciones. Devuelve las condiciones exactas a decir.',
          parameters: {
            type: 'object',
            properties: {
              codigo_oferta: { type: 'string', enum: codes, description: 'Código de la opción permitida.' },
              fecha_mencionada: { type: 'string', description: 'La fecha TAL COMO la dijo el cliente, ej. "el viernes", "el 25". Vacío si no dijo.' },
              monto: { type: 'number', description: 'Monto que el cliente propone pagar (solo pago parcial).' },
              numero_de_cuotas: { type: 'integer', description: 'Número de pagos (solo planes).' },
            },
            required: ['codigo_oferta'],
          },
        },
      },
      {
        type: 'function',
        function: {
          name: 'registrar_compromiso',
          description: 'Registra el compromiso después de un "sí" explícito del cliente a un resumen con opción, monto y fecha.',
          parameters: {
            type: 'object',
            properties: {
              codigo_oferta: { type: 'string', enum: codes },
              cliente_confirmo: { type: 'boolean', description: 'true SOLO si el cliente dijo sí explícito al resumen.' },
            },
            required: ['codigo_oferta', 'cliente_confirmo'],
          },
        },
      },
    );
  }
  tools.push(
    {
      type: 'function',
      function: {
        name: 'enviar_por_correo',
        description: 'Envía por correo la confirmación del compromiso con el link de pago y un video breve. Úsalo cuando el cliente acepte.',
        parameters: { type: 'object', properties: {} },
      },
    },
    {
      type: 'function',
      function: {
        name: 'agendar_rellamada',
        description: 'Agenda volver a llamar cuando el cliente pide que lo llamen otro día.',
        parameters: {
          type: 'object',
          properties: {
            fecha_mencionada: { type: 'string', description: 'Tal como la dijo el cliente.' },
            franja: { type: 'string', enum: ['manana', 'tarde', 'noche'] },
          },
          required: ['fecha_mencionada'],
        },
      },
    },
    {
      type: 'function',
      function: {
        name: 'escalar_a_humano',
        description: 'Transfiere a un asesor humano: el cliente lo pide, hay disputa, posible fraude o mucha molestia.',
        parameters: { type: 'object', properties: { motivo: { type: 'string' } }, required: ['motivo'] },
      },
    },
    {
      type: 'function',
      function: {
        name: 'finalizar_llamada',
        description: 'Indica que la conversación terminó. Después de llamarla, despídete en una frase.',
        parameters: {
          type: 'object',
          properties: { motivo: { type: 'string', enum: Object.keys(FINAL_OUTCOME) } },
          required: ['motivo'],
        },
      },
    },
  );
  return tools;
}

/** Normaliza frases que el resolver no cubre: "viernes 25 de septiembre", "mañana en la tarde", "dentro de 8 días". */
export function resolveDate(text: unknown): ReturnType<typeof resolveSpanishDate> {
  if (typeof text !== 'string' || !text.trim()) return null;
  const raw = text.trim();
  const candidates = [
    raw,
    raw.replace(/\b(en|por)\s+la\s+(mañana|manana|tarde|noche)\b/gi, '').trim(),
    raw.replace(/^(el\s+)?(lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo)\s+(?=\d)/i, 'el ').trim(),
    raw.replace(/\bdentro\s+de\b/gi, 'en').trim(),
    raw.replace(/\b(la\s+)?otra\s+semana\b/gi, 'la próxima semana').trim(),
  ];
  for (const candidate of candidates) {
    const resolved = candidate ? resolveSpanishDate(candidate) : null;
    if (resolved) return resolved;
  }
  return null;
}

function offerParams(state: ConversationState, code: string, args: Json): { params: Json; dateLabel: string | null } {
  const offer = state.context.offers.find((o) => o.code === code);
  const resolved = resolveDate(args.fecha_mencionada);
  const previous = state.validated[code] ?? {};
  // Si el modelo revalida sin una fecha entendible, se conserva la fecha ya validada (evita que las condiciones cambien solas)
  const date = resolved?.date
    ?? (previous.remaining_date ?? previous.new_date ?? previous.first_payment_date ?? previous.callback_date ?? previous.date) as string | undefined;
  const params: Json = {};
  switch (offer?.offer_type) {
    case 'DATE_EXTENSION': if (date) params.new_date = date; break;
    case 'PARTIAL_PAYMENT':
      if (typeof args.monto === 'number') params.amount = args.monto;
      else if (typeof previous.amount === 'number') params.amount = previous.amount;
      if (date) params.remaining_date = date;
      break;
    case 'INSTALLMENT_PLAN':
      if (typeof args.numero_de_cuotas === 'number') params.installments = args.numero_de_cuotas;
      else if (typeof previous.installments === 'number') params.installments = previous.installments;
      if (date) params.first_date = date;
      break;
    case 'CALLBACK': if (date) params.callback_date = date; break;
    case 'FULL_PAYMENT': case 'REMINDER': if (date) params.date = date; break;
    default: break;
  }
  return { params, dateLabel: resolved?.label ?? null };
}

export async function executeTool(state: ConversationState, name: string, args: Json): Promise<Json> {
  const conv = state.conversationId;
  switch (name) {
    case 'validar_oferta': {
      const code = String(args.codigo_oferta ?? '');
      const { params, dateLabel } = offerParams(state, code, args);
      const res = await db.validateOffer(conv, code, params);
      if (res.valid) {
        state.validated[code] = res.normalized_params;
        state.lastPresentedOffer = code;
      }
      return {
        valida: res.valid,
        condiciones: res.valid ? res.terms_text : null,
        errores: res.errors.map(humanError),
        fecha_interpretada: dateLabel,
        requiere_aprobacion: res.requires_approval,
        instruccion: res.valid
          ? 'Di estas condiciones con tus palabras SIN cambiar montos ni fechas y pide un sí explícito. Cuando el cliente diga sí, llama registrar_compromiso de inmediato sin repetir las condiciones.'
          : 'No ofrezcas esto así. Explica el límite con amabilidad y propone otra opción o fecha permitida.',
      };
    }
    case 'registrar_compromiso': {
      const code = String(args.codigo_oferta ?? '');
      const params = state.validated[code];
      if (!params) return { ok: false, error: 'Primero usa validar_oferta con esta opción y di las condiciones.' };
      const res = await db.registerCommitment(conv, code, params, args.cliente_confirmo === true);
      if (!res.ok || !res.receipt_code) {
        return { ok: false, errores: (res.errors ?? []).map(humanError), instruccion: res.instruction ?? null };
      }
      const offer = state.context.offers.find((o) => o.code === code);
      state.commitment = {
        receipt: res.receipt_code, code, status: res.status ?? 'pending',
        requiresApproval: !!res.requires_approval, generatesPaymentLink: !!offer?.generates_payment_link,
      };
      return {
        ok: true, codigo_recibo: res.receipt_code, requiere_aprobacion: !!res.requires_approval,
        instruccion: res.requires_approval
          ? 'Confirma que la SOLICITUD quedó registrada y que la revisa un asesor. No digas que está aprobada. Ofrece enviar el resumen por correo.'
          : 'Confirma que quedó registrado y ofrece enviarle por correo la confirmación con el link de pago.',
      };
    }
    case 'enviar_por_correo': {
      if (!state.commitment) return { ok: false, error: 'Aún no hay compromiso registrado.' };
      void sendConfirmationEmail(state);
      return { ok: true, instruccion: 'Dile que en unos minutos le llega el correo con la confirmación y el link.' };
    }
    case 'agendar_rellamada': {
      const code = state.context.offers.find((o) => o.offer_type === 'CALLBACK')?.code ?? 'REAGENDAR';
      const resolved = resolveDate(args.fecha_mencionada);
      const params: Json = { window: args.franja ?? 'manana', ...(resolved ? { callback_date: resolved.date } : {}) };
      const v = await db.validateOffer(conv, code, params);
      if (!v.valid) return { ok: false, errores: v.errors.map(humanError), instruccion: 'Pide un día dentro de los próximos 5 días.' };
      const r = await db.registerCommitment(conv, code, v.normalized_params, true);
      if (r.ok) {
        state.endCall = true;
        state.outcome = 'CALLBACK_SCHEDULED';
      }
      return { ok: r.ok, fecha: resolved?.label ?? null, instruccion: 'Confirma el día y la franja y despídete.',
               despedida: r.ok ? `Perfecto, le llamamos el ${resolved?.label ?? 'día acordado'}. Que tenga un buen día.` : null };
    }
    case 'escalar_a_humano': {
      await db.requestEscalation(conv, String(args.motivo ?? 'Solicitud del cliente'));
      state.endCall = true;
      state.outcome = 'HUMAN_ESCALATION';
      return { ok: true, instruccion: 'Di que un asesor le contactará en un máximo de 24 horas hábiles y despídete.',
               despedida: 'Entendido. Un asesor le contactará en un máximo de 24 horas hábiles. Gracias por su paciencia.' };
    }
    case 'finalizar_llamada': {
      const motivo = String(args.motivo ?? 'otro');
      const scorecard: Json | null =
        motivo === 'no_contactar' ? { do_not_contact_request: 'yes', confidence: 0.95 }
        : motivo === 'persona_equivocada' ? { wrong_person: 'yes', confidence: 0.95 }
        : motivo === 'no_es_buen_momento' ? { availability: 'callback_requested', confidence: 0.9 }
        : null;
      if (scorecard) void db.evaluateTurn(conv, scorecard, undefined, { evaluator_model_key: 'agent.tool' }).catch(() => null);
      state.endCall = true;
      state.outcome = state.outcome ?? FINAL_OUTCOME[motivo] ?? 'FOLLOW_UP_REQUIRED';
      return { ok: true, instruccion: 'Despídete con calidez en una sola frase.', despedida: FAREWELLS[motivo] ?? FAREWELLS.otro };
    }
    default:
      return { ok: false, error: `Herramienta desconocida: ${name}` };
  }
}
