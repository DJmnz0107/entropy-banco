import { GoogleGenAI } from '@google/genai';
import { knowledge } from './knowledge.js';

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
const MODEL = process.env.GEMINI_MODEL || 'gemini-3.6-flash';

export async function askGemini(history, userMessage) {
  const contents = [...history, { role: 'user', parts: [{ text: userMessage }] }];

  const response = await ai.models.generateContent({
    model: MODEL,
    contents,
    config: {
      systemInstruction: knowledge,
    },
  });

  const reply = response.text;

  return {
    reply,
    history: [...contents, { role: 'model', parts: [{ text: reply }] }],
  };
}
