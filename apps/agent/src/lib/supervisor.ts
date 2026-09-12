/**
 * Supervisor LLM — generates scorecard for evaluate_turn.
 *
 * Uses Gemini Flash-Lite (text mode, temp=0) to classify each customer turn.
 * Runs in parallel with audio streaming — results are injected as [CONTROL] messages.
 */

import 'dotenv/config';

const API_KEY = process.env.GEMINI_API_KEY;
const SUPERVISOR_MODEL = 'gemini-2.0-flash-lite'; // text-only supervisor

export interface Scorecard {
  intent: 'pay' | 'negotiate' | 'defer' | 'dispute' | 'escalate' | 'end' | 'unknown';
  sentiment: 'positive' | 'neutral' | 'negative' | 'unknown';
  sentiment_score: number; // -1.0 to 1.0
  engagement: 'high' | 'medium' | 'low' | 'unknown';
  resistance: 'yes' | 'no' | 'unknown';
  commitment_signal: 'yes' | 'no' | 'unknown';
  confidence: number; // 0.0 to 1.0
  identity_confirmed: 'yes' | 'no' | 'unknown';
  explicit_refusal: 'yes' | 'no' | 'unknown';
  do_not_contact_request: 'yes' | 'no' | 'unknown';
  third_party_detected: 'yes' | 'no' | 'unknown';
  callback_request: 'yes' | 'no' | 'unknown';
  fraud_signal: 'yes' | 'no' | 'unknown';
  frustration_signal: 'yes' | 'no' | 'unknown';
  notes: string;
}

const SCORECARD_SCHEMA = `
Responde SOLO con un JSON válido con esta estructura:
{
  "intent": "pay|negotiate|defer|dispute|escalate|end|unknown",
  "sentiment": "positive|neutral|negative|unknown",
  "sentiment_score": <número entre -1.0 y 1.0>,
  "engagement": "high|medium|low|unknown",
  "resistance": "yes|no|unknown",
  "commitment_signal": "yes|no|unknown",
  "confidence": <número entre 0.0 y 1.0>,
  "identity_confirmed": "yes|no|unknown",
  "explicit_refusal": "yes|no|unknown",
  "do_not_contact_request": "yes|no|unknown",
  "third_party_detected": "yes|no|unknown",
  "callback_request": "yes|no|unknown",
  "fraud_signal": "yes|no|unknown",
  "frustration_signal": "yes|no|unknown",
  "notes": "<breve observación>"
}
Reglas: usa SOLO "yes"|"no"|"unknown" para los campos booleanos. "unknown" nunca equivale a "no".
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

  const prompt = `Eres el supervisor de una conversación de cobranza bancaria. Analiza el último mensaje del cliente y clasifícalo.

Etapa actual: ${stage}

Historial reciente:
${historySnippet}

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
          generationConfig: { temperature: 0, responseMimeType: 'application/json' },
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
    // Return safe default so the conversation continues
    return {
      intent: 'unknown',
      sentiment: 'unknown',
      sentiment_score: 0,
      engagement: 'unknown',
      resistance: 'unknown',
      commitment_signal: 'unknown',
      confidence: 0.5,
      identity_confirmed: 'unknown',
      explicit_refusal: 'unknown',
      do_not_contact_request: 'unknown',
      third_party_detected: 'unknown',
      callback_request: 'unknown',
      fraud_signal: 'unknown',
      frustration_signal: 'unknown',
      notes: 'Supervisor error — default scorecard used',
    };
  }
}
