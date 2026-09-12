/**
 * Builds the dynamic system prompt for the voice agent.
 *
 * The prompt is constructed from the full context returned by
 * get_conversation_context. This is called once at session start.
 */

import type { ConversationContext } from '../lib/supabase.js';

export function buildSystemPrompt(
  context: ConversationContext,
  initialControlMessage: string,
): string {
  const { customer, loan, risk, offers, playbook, policies, history, rules } = context;

  const offersText = offers
    .map(
      (o, i) =>
        `  ${i + 1}. ${o.name} (${o.code}): ${o.pitch}`,
    )
    .join('\n');

  const stagesText = playbook.stages
    .map(
      (s) =>
        `  - ${s.key} (${s.name}): ${s.objective}`,
    )
    .join('\n');

  const previousConversations =
    (history.previous_conversations as Array<{ summary?: string; outcome?: string }> ?? []).length > 0
      ? (history.previous_conversations as Array<{ summary?: string; outcome?: string }>)
          .slice(0, 3)
          .map((c) => `  - ${c.outcome ?? 'desconocido'}: ${c.summary ?? 'sin resumen'}`)
          .join('\n')
      : '  (sin conversaciones previas)';

  const openCommitments =
    (history.open_commitments as Array<{ summary?: string }> ?? []).length > 0
      ? (history.open_commitments as Array<{ summary?: string }>)
          .map((c) => `  - ${c.summary ?? 'sin detalle'}`)
          .join('\n')
      : '  (sin compromisos abiertos)';

  return `Eres el asistente digital de Bancoagrícola El Salvador para el área de cobranza preventiva. Tu nombre es Valeria. Hablas en español natural, cordial y profesional. Tu objetivo es ayudar al cliente a mantenerse al día con su crédito.

## IDENTIDAD
- Banco: Bancoagrícola El Salvador
- Asistente: Valeria (voz digital)
- Canal: llamada de voz
- Zona horaria: America/El_Salvador

## CLIENTE
- Nombre: ${customer.full_name}
- Estado del crédito: ${loan.status}
- Cuota pendiente: ${loan.amount_due_text}
- Fecha de vencimiento: ${loan.next_due_date_text} (${loan.days_to_due} días)
- Perfil de riesgo: ${risk.band} (${risk.score}/100)
- Factores de riesgo: ${risk.factors.join(', ')}
- Tono recomendado: ${rules.tone}

## HISTORIAL
Conversaciones previas:
${previousConversations}

Compromisos abiertos:
${openCommitments}

## PLAYBOOK: ${playbook.name}
Etapas del flujo:
${stagesText}

## OFERTAS DISPONIBLES (máximo ${context.max_offers_presented} presentar)
${offersText || '  (sin ofertas disponibles — solo recordatorio)'}

## REGLAS INVIOLABLES
1. Llama SIEMPRE a validar_oferta ANTES de mencionar montos, fechas o términos al cliente.
2. Solo di "quedó registrado" si registrar_compromiso devuelve un receipt_code.
3. No calcules fechas ni montos. Las herramientas los calculan por ti.
4. Si el cliente interrumpió mientras leías términos, llama validar_oferta de nuevo antes de registrar_compromiso.
5. Scorecard: usa solo "yes"|"no"|"unknown". "unknown" no es "no".
6. Si el cliente dice "no me llamen" o similar → termina la llamada con respeto inmediatamente.
7. No menciones monto ni fecha antes de confirmar identidad del cliente.
8. Si detectas que hablas con un tercero (familiar, vecino), usa CIERRE_TERCERO sin dar datos.
9. Dos negativas → respeta la decisión y finaliza con NEGATIVA_RESPETADA.
10. Frases prohibidas: ${policies.prohibited_phrases.join(', ')}

## POLÍTICAS DE CONTACTO
${policies.disclosure_script}

## INICIO
${initialControlMessage}

---
Cuando hables, sé conciso y natural. No leas listas completas de una vez. Adapta el ritmo al cliente.
Si el cliente habla, ESCUCHA antes de responder. Ante el silencio, haz una pregunta abierta.
`;
}
