import './env.js';

import express from 'express';
import { askGemini } from './gemini.js';
import { sendWhatsAppMessage } from './whatsapp.js';
import { getHistory, saveHistory } from './supabase.js';

const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Verificación del webhook (Meta llama esto una vez al configurarlo)
app.get('/webhook', (req, res) => {
  const mode = req.query['hub.mode'];
  const token = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];

  if (mode === 'subscribe' && token === process.env.META_VERIFY_TOKEN) {
    res.status(200).send(challenge);
  } else {
    res.sendStatus(403);
  }
});

// Recepción de mensajes entrantes de WhatsApp
app.post('/webhook', async (req, res) => {
  res.sendStatus(200); // Meta espera una respuesta rápida; procesamos después

  try {
    const message = req.body.entry?.[0]?.changes?.[0]?.value?.messages?.[0];
    if (!message || message.type !== 'text') return;

    const from = message.from;
    const text = message.text.body;

    const history = await getHistory(from);
    const { reply, history: updatedHistory } = await askGemini(history, text);

    await saveHistory(from, updatedHistory);
    await sendWhatsAppMessage(from, reply);
  } catch (err) {
    console.error('Error procesando mensaje de WhatsApp:', err);
  }
});

// Endpoint de prueba local: misma lógica que el webhook, sin depender de Meta.
// Útil mientras no tengas access token / phone number ID.
app.post('/test-chat', async (req, res) => {
  try {
    const { from = 'test-user', message } = req.body;
    if (!message) return res.status(400).json({ error: 'Falta "message" en el body' });

    const history = await getHistory(from);
    const { reply, history: updatedHistory } = await askGemini(history, message);
    await saveHistory(from, updatedHistory);

    res.json({ reply });
  } catch (err) {
    console.error('Error en /test-chat:', err);
    res.status(500).json({ error: 'Error interno' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor corriendo en http://localhost:${PORT}`);
});