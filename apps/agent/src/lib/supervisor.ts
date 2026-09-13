/**
 * Supervisor LLM — generates scorecard for evaluate_turn.
 *
 * Uses Gemini Flash (text mode, temp=0) to classify each customer turn.
 * Fields match the 26 criteria defined in Postgres `evaluation_criteria`.
 * Runs in parallel with audio streaming — results are injected as [CONTROL] messages.
 */

import 'dotenv/config';

const API_KEY = process.env.GEMINI_API_KEY;
const SUPERVISOR_MODEL = process.env.GEMINI_MODEL ?? 'gemini-3.6-flash';

export interface Scorecard {
  intent:
    | 'WILL_PAY'
    | 'NEEDS_ALTERNATIVE_DATE'
    | 'FINANCIAL_DIFFICULTY'
    | 'ASKS_QUESTION'
    | 'REFUSES'
    | 'ANGRY'
    | 'EVASIVE'
    | 'REQUESTS_HUMAN'
    | 'DISPUTE'
    | 'POSSIBLE_FRAUD'
    | 'ALREADY_PAID'
    | 'CONFIRMS'
    | 'WRONG_PERSON'
    | 'UNKNOWN';
  sentiment: 'POSITIVE' | 'NEUTRAL' | 'CONCERNED' | 'FRUSTRATED' | 'ANGRY';
  sentiment_score: number; // -1.0 to 1.0
  engagement: number; // 0.0 to 1.0
  resistance: number; // 0.0 to 1.0
  comprehension: number; // 0.0 to 1.0
  payment_capacity: 'full' | 'partial' | 'none' | 'unknown';
  difficulty_reason:
    | 'none'
    | 'income_delay'
    | 'job_loss'
    | 'health'
    | 'harvest'
    | 'climate'
    | 'unexpected_expense'
    | 'remittance'
    | 'other'
    | 'unknown';
  offer_interest: 'accepted' | 'interested' | 'neutral' | 'rejected' | 'unknown';
  offer_code: string;
  commitment_signal: 'none' | 'weak' | 'strong' | 'explicit';
  extracted_date_text: string;
  extracted_amount_text: string;
  confirmation_given: 'yes' | 'no' | 'unknown';
  explicit_refusal: 'yes' | 'no' | 'unknown';
  do_not_contact_request: 'yes' | 'no' | 'unknown';
  requests_human: 'yes' | 'no' | 'unknown';
  dispute_or_fraud: 'yes' | 'no' | 'unknown';
  accepts_whatsapp_followup: 'yes' | 'no' | 'unknown';
  already_paid_claim: 'yes' | 'no' | 'unknown';
  is_backchannel: 'yes' | 'no' | 'unknown';
  identity_confirmed: 'yes' | 'no' | 'unknown';
  wrong_person: 'yes' | 'no' | 'unknown';
  confidence: number; // 0.0 to 1.0
  evidence: string;
}

const SCORECARD_SCHEMA = `
Responde ÚNICAMENTE con un objeto JSON válido (sin markdown, sin explicaciones):
{
  "intent": "WILL_PAY | NEEDS_ALTERNATIVE_DATE | FINANCIAL_DIFFICULTY | ASKS_QUESTION | REFUSES | ANGRY | EVASIVE | REQUESTS_HUMAN | DISPUTE | POSSIBLE_FRAUD | ALREADY_PAID | CONFIRMS | WRONG_PERSON | UNKNOWN",
  "sentiment": "POSITIVE | NEUTRAL | CONCERNED | FRUSTRATED | ANGRY",
  "sentiment_score": <número entre -1.0 y 1.0>,
  "engagement": <número entre 0.0 y 1.0>,
  "resistance": <número entre 0.0 y 1.0>,
  "comprehension": <número entre 0.0 y 1.0>,
  "payment_capacity": "full | partial | none | unknown",
  "difficulty_reason": "none | income_delay | job_loss | health | harvest | climate | unexpected_expense | remittance | other | unknown",
  "offer_interest": "accepted | interested | neutral | rejected | unknown",
  "offer_code": "<código de la oferta que mencionó o aceptó, ej: PAGO_TOTAL, PLAN_3_CUOTAS, EXTENSION_15, o vacio \"\">",
  "commitment_signal": "none | weak | strong | explicit",
  "extracted_date_text": "<fecha literal mencionada por el cliente, ej: \"el viernes\", o vacio \"\">",
  "extracted_amount_text": "<monto literal mencionado por el cliente, ej: \"50 dólares\", o vacio \"\">",
  "confirmation_given": "yes | no | unknown",
  "explicit_refusal": "yes | no | unknown",
  "do_not_contact_request": "yes | no | unknown",
  "requests_human": "yes | no | unknown",
  "dispute_or_fraud": "yes | no | unknown",
  "accepts_whatsapp_followup": "yes | no | unknown",
  "already_paid_claim": "yes | no | unknown",
  "is_backchannel": "yes | no | unknown",
  "identity_confirmed": "yes | no | unknown",
  "wrong_person": "yes | no | unknown",
  "confidence": <número entre 0.0 y 1.0>,
  "evidence": "<frase textual corta del cliente que justifica la clasificación>"
}

Reglas críticas:
1. En confirmation_given, usa "yes" ÚNICAMENTE si el cliente dijo explícitamente "sí", "de acuerdo", "acepto" a una confirmación del agente. Un "ajá" o "mjm" es "unknown".
2. Si el cliente dice "soy yo" o confirma su nombre en APERTURA -> identity_confirmed = "yes".
3. Si el cliente dice "no está", "número equivocado" -> wrong_person = "yes", intent = "WRONG_PERSON".
4. Si el cliente dice "ya pagué" -> already_paid_claim = "yes", intent = "ALREADY_PAID".
5. Si el cliente pide no ser llamado -> do_not_contact_request = "yes".
6. Si el cliente dice que no puede pagar todo -> payment_capacity = "partial" o "none", intent = "FINANCIAL_DIFFICULTY".
`;

export async function generateScorecard(
  customerText: string,
  conversationHistory: Array<{ role: string; text: string }>,
  stage: string,
): Promise<Scorecard> {
  const historySnippet = conversationHistory
    .slice(-6)
    .map((m) => `${m.role === 'agent' ? 'Agente' : 'Cliente'}: ${m.text}`)
    .join('\n');

  const prompt = `Eres el supervisor analista de conversaciones de cobranza bancaria de Bancoagrícola El Salvador.
Evalúa con precisión el último turno del cliente.

Etapa actual: ${stage}

Historial reciente:
${historySnippet || '(inicio de la llamada)'}

Último mensaje del cliente:
"${customerText}"

${SCORECARD_SCHEMA}`;

  try {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${SUPERVISOR_MODEL}:generateContent?key=${API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0,
            responseMimeType: 'application/json',
          },
        }),
      },
    );

    if (!response.ok) {
      throw new Error(`Supervisor API error: ${response.status}`);
    }

    const data = (await response.json()) as {
      candidates: Array<{ content: { parts: Array<{ text: string }> } }>;
    };

    const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? '{}';
    const scorecard = JSON.parse(text) as Scorecard;
    return scorecard;
  } catch (err) {
    console.error('[supervisor] Error generating scorecard:', err);
    // Safe default to keep conversation progressing
    return {
      intent: 'UNKNOWN',
      sentiment: 'NEUTRAL',
      sentiment_score: 0,
      engagement: 0.5,
      resistance: 0,
      comprehension: 0.8,
      payment_capacity: 'unknown',
      difficulty_reason: 'none',
      offer_interest: 'unknown',
      offer_code: '',
      commitment_signal: 'none',
      extracted_date_text: '',
      extracted_amount_text: '',
      confirmation_given: 'unknown',
      explicit_refusal: 'unknown',
      do_not_contact_request: 'unknown',
      requests_human: 'unknown',
      dispute_or_fraud: 'unknown',
      accepts_whatsapp_followup: 'unknown',
      already_paid_claim: 'unknown',
      is_backchannel: 'no',
      identity_confirmed: stage === 'APERTURA' ? 'unknown' : 'yes',
      wrong_person: 'unknown',
      confidence: 0.5,
      evidence: 'Fallback scorecard',
    };
  }
}
