/**
 * Tool definitions for Gemini Live.
 *
 * These are the functions the voice agent can call during a conversation.
 * Each call is intercepted by the session handler which executes the
 * corresponding Supabase RPC and returns the result to Gemini.
 */

import type { GeminiLiveTool } from '../lib/gemini-live.js';

export const voiceTools: GeminiLiveTool[] = [
  {
    functionDeclarations: [
      {
        name: 'validar_oferta',
        description:
          'Valida una opción u oferta con los parámetros dados antes de decir montos o fechas. Devuelve el texto exacto de términos que debes decir al cliente. Códigos válidos: PAGO_TOTAL, RECORDATORIO, EXTENSION_15, EXTENSION_POST_COSECHA, PAGO_PARCIAL_50, PLAN_3_CUOTAS, PLAN_6_CUOTAS, CONDONACION_RECARGO, REAGENDAR, ASESOR_HUMANO.',
        parameters: {
          type: 'OBJECT',
          properties: {
            offer_code: {
              type: 'string',
              description:
                'Código de la oferta: PAGO_TOTAL, RECORDATORIO, EXTENSION_15, EXTENSION_POST_COSECHA, PAGO_PARCIAL_50, PLAN_3_CUOTAS, PLAN_6_CUOTAS, CONDONACION_RECARGO, REAGENDAR, ASESOR_HUMANO.',
              enum: [
                'PAGO_TOTAL',
                'RECORDATORIO',
                'EXTENSION_15',
                'EXTENSION_POST_COSECHA',
                'PAGO_PARCIAL_50',
                'PLAN_3_CUOTAS',
                'PLAN_6_CUOTAS',
                'CONDONACION_RECARGO',
                'REAGENDAR',
                'ASESOR_HUMANO',
              ],
            },
            params: {
              type: 'string',
              description:
                'JSON string con parámetros de la oferta (opcional). Ej: {"installments": 3}, {"new_date": "2026-09-25"}, {"amount": 50}. Deja vacío si no hay parámetros adicionales.',
            },
          },
          required: ['offer_code'],
        },
      },
      {
        name: 'registrar_compromiso',
        description:
          'Registra el compromiso en la base de datos tras la confirmación explícita del cliente ("sí", "de acuerdo"). Requiere haber llamado validar_oferta previamente. Si devuelve receipt_code, confirma al cliente que quedó registrado con ese código.',
        parameters: {
          type: 'OBJECT',
          properties: {
            offer_code: {
              type: 'string',
              description: 'Código de la oferta acordada: PAGO_TOTAL, EXTENSION_15, PLAN_3_CUOTAS, etc.',
            },
            params: {
              type: 'string',
              description: 'JSON string con los parámetros acordados (o vacío si usas los de validar_oferta).',
            },
            customer_confirmed: {
              type: 'string',
              description:
                'Usa "true" SOLO si el cliente confirmó explícitamente ("sí", "acepto").',
              enum: ['true', 'false'],
            },
          },
          required: ['offer_code', 'customer_confirmed'],
        },
      },
      {
        name: 'crear_link_de_pago',
        description:
          'Crea un link de pago único para el cliente. Llama solo si el cliente quiere pagar en línea o si se acordó enviar el link por WhatsApp.',
        parameters: {
          type: 'OBJECT',
          properties: {},
        },
      },
      {
        name: 'solicitar_escalacion',
        description:
          'Escala la conversación a un agente humano. Usa cuando el cliente lo pide explícitamente, hay una disputa abierta, o la situación requiere decisiones fuera de tu alcance.',
        parameters: {
          type: 'OBJECT',
          properties: {
            reason: {
              type: 'string',
              description: 'Motivo de la escalación en español.',
            },
          },
          required: ['reason'],
        },
      },
      {
        name: 'registrar_rellamada',
        description:
          'Registra una promesa de rellamada para otra fecha. Usa cuando el cliente pide que lo llamen otro día.',
        parameters: {
          type: 'OBJECT',
          properties: {
            callback_date: {
              type: 'string',
              description: 'Fecha de rellamada en formato YYYY-MM-DD (America/El_Salvador).',
            },
            window: {
              type: 'string',
              description:
                'Ventana horaria preferida. Valores: morning, afternoon, evening, any.',
              enum: ['morning', 'afternoon', 'evening', 'any'],
            },
          },
          required: ['callback_date'],
        },
      },
    ],
  },
];
