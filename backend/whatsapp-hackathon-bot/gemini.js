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

// Llamada del "supervisor": evalúa el turno y devuelve el scorecard en JSON
// validado contra el output_schema guardado en prompt_versions.
export async function askScorecard(promptTemplate, vars, schema) {
  const prompt = renderTemplate(promptTemplate, vars);
  const response = await ai.models.generateContent({
    model: MODEL,
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    config: {
      responseMimeType: 'application/json',
      responseSchema: schema,
    },
  });
  return JSON.parse(response.text);
}

// Llamada del "composer": redacta el mensaje que se le manda al cliente.
export async function askComposer(promptTemplate, vars) {
  const prompt = renderTemplate(promptTemplate, vars);
  const response = await ai.models.generateContent({
    model: MODEL,
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
  });
  return response.text.trim();
}
