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
          'Valida una oferta de pago con los parámetros dados. Devuelve el texto de términos y condiciones que DEBES leer textualmente al cliente antes de pedir confirmación. Llama SIEMPRE antes de mencionar montos o fechas.',
        parameters: {
          type: 'OBJECT',
          properties: {
            offer_code: {
              type: 'string',
              description:
                'Código de la oferta. Valores posibles: FULL_PAYMENT, PARTIAL_PAYMENT, INSTALLMENT_PLAN, DATE_EXTENSION, FEE_WAIVER, CALLBACK, REMINDER',
            },
            params: {
              type: 'string',
              description:
                'JSON string con parámetros específicos de la oferta. Ej: {"installments": 3, "first_date": "2026-09-20"}. Nunca inventes fechas ni montos — el sistema los calcula.',
            },
          },
          required: ['offer_code'],
        },
      },
      {
        name: 'registrar_compromiso',
        description:
          'Registra el compromiso de pago SOLO después de que el cliente dé una confirmación verbal explícita ("sí", "acepto", "de acuerdo"). Requiere haber llamado validar_oferta previamente. Si devuelve receipt_code, léelo al cliente.',
        parameters: {
          type: 'OBJECT',
          properties: {
            offer_code: {
              type: 'string',
              description: 'Código de la oferta acordada.',
            },
            params: {
              type: 'string',
              description: 'JSON string con los parámetros confirmados de la oferta.',
            },
            customer_confirmed: {
              type: 'string',
              description:
                'Usa "true" si el cliente confirmó explícitamente. Nunca registres sin confirmación real.',
              enum: ['true', 'false'],
            },
          },
          required: ['offer_code', 'params', 'customer_confirmed'],
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
