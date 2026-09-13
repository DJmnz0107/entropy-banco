import { GoogleGenAI } from '@google/genai';

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
const MODEL = process.env.GEMINI_MODEL || 'gemini-3.6-flash';

export function renderTemplate(template, vars) {
  let out = template;
  for (const [key, value] of Object.entries(vars)) {
    out = out.split(`{${key}}`).join(value ?? '');
  }
  return out;
}

function isQuotaError(err) {
  const text = JSON.stringify(err?.message ?? err ?? '');
  return err?.status === 429 || /RESOURCE_EXHAUSTED|quota/i.test(text);
}

// Reintenta llamadas a Gemini que fallan por errores transitorios (503
// "modelo saturado", timeouts de red/gateway). NO reintenta errores de
// cuota (429) porque un segundo intento inmediato solo gasta otra unidad
// de la misma cuota agotada sin ninguna posibilidad de éxito.
async function withRetry(fn, { retries = 2, delayMs = 1000 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (isQuotaError(err) || attempt === retries) throw err;
      console.warn(`Llamada a Gemini falló (intento ${attempt + 1}/${retries + 1}), reintentando...`, err?.message ?? err);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}

// Llamada del "supervisor": evalúa el turno y devuelve el scorecard en JSON
// validado contra el output_schema guardado en prompt_versions.
export async function askScorecard(promptTemplate, vars, schema) {
  const prompt = renderTemplate(promptTemplate, vars);
  return withRetry(async () => {
    const response = await ai.models.generateContent({
      model: MODEL,
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      config: {
        responseMimeType: 'application/json',
        responseSchema: schema,
      },
    });
    return JSON.parse(response.text);
  });
}

const OFFER_PARAMS_SCHEMA = {
  type: 'object',
  properties: {
    new_date: { type: 'string', description: 'Fecha ISO YYYY-MM-DD propuesta para mover el pago (DATE_EXTENSION), o cadena vacía si no aplica.' },
    date: { type: 'string', description: 'Fecha ISO YYYY-MM-DD de pago (FULL_PAYMENT/REMINDER/PARTIAL_PAYMENT), o cadena vacía.' },
    amount: { type: 'number', description: 'Monto que el cliente propuso pagar ahora (PARTIAL_PAYMENT), o 0 si no aplica.' },
    installments: { type: 'integer', description: 'Número de cuotas propuesto (INSTALLMENT_PLAN), o 0 si no aplica.' },
    down_payment: { type: 'number', description: 'Pago inicial propuesto (INSTALLMENT_PLAN), o 0 si no aplica.' },
    first_date: { type: 'string', description: 'Fecha ISO YYYY-MM-DD del primer pago del plan, o cadena vacía.' },
    callback_date: { type: 'string', description: 'Fecha ISO YYYY-MM-DD para que le vuelvan a llamar (CALLBACK), o cadena vacía.' },
    window: { type: 'string', description: 'Franja horaria para la rellamada: "manana", "tarde" o "noche", o cadena vacía si no aplica.' },
  },
  required: ['new_date', 'date', 'amount', 'installments', 'down_payment', 'first_date', 'callback_date', 'window'],
};

// Convierte lo que el cliente dijo en LENGUAJE NATURAL ("el próximo viernes",
// "diciembre") a parámetros reales que validate_offer pueda entender. Las
// fechas relativas se resuelven contra `todayIso` y la fecha de vencimiento
// original, para que "diciembre" no se cuele como año equivocado, etc.
export async function extractOfferParams({ offerType, transcript, todayIso, dueDateIso }) {
  const prompt = `Hoy es ${todayIso} (zona horaria El Salvador). La cuota original vence el ${dueDateIso}.
El cliente está proponiendo condiciones para una oferta de tipo "${offerType}" en esta conversación:
${transcript}

Extrae los parámetros concretos que el cliente propuso, convirtiendo cualquier fecha relativa ("el próximo viernes", "diciembre", "en dos semanas") a una fecha ISO real usando "hoy" como referencia. Si un campo no aplica o no se mencionó, usa cadena vacía ("") o 0 según el tipo. No inventes valores que el cliente no mencionó.`;

  const raw = await withRetry(async () => {
    const response = await ai.models.generateContent({
      model: MODEL,
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      config: {
        responseMimeType: 'application/json',
        responseSchema: OFFER_PARAMS_SCHEMA,
      },
    });
    return JSON.parse(response.text);
  });
  // Limpia campos vacíos/cero para que validate_offer use sus propios
  // valores por defecto en vez de recibir "" o 0 como si fueran reales.
  const params = {};
  for (const [key, value] of Object.entries(raw)) {
    if (value === '' || value === 0) continue;
    params[key] = value;
  }
  return params;
}

// Llamada del "composer": redacta el mensaje que se le manda al cliente.
export async function askComposer(promptTemplate, vars) {
  const prompt = renderTemplate(promptTemplate, vars);
  return withRetry(async () => {
    const response = await ai.models.generateContent({
      model: MODEL,
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
    });
    return response.text.trim();
  });
}
