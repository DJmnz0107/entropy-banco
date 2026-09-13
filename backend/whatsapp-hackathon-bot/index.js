import './env.js';

import express from 'express';
import { sendWhatsAppMessage } from './whatsapp.js';
import { handleIncomingMessage } from './engine.js';

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

  console.log(`GET /webhook (verificación) mode=${mode} token=${token}`);

  if (mode === 'subscribe' && token === process.env.META_VERIFY_TOKEN) {
    res.status(200).send(challenge);
  } else {
    res.sendStatus(403);
  }
});

// Recepción de mensajes entrantes de WhatsApp
app.post('/webhook', async (req, res) => {
  console.log('POST /webhook recibido:', JSON.stringify(req.body));
  res.sendStatus(200); // Meta espera una respuesta rápida; procesamos después

  try {
    const message = req.body.entry?.[0]?.changes?.[0]?.value?.messages?.[0];
    if (!message || message.type !== 'text') {
      console.log('Payload sin mensaje de texto (probablemente un status/delivery update); se ignora.');
      return;
    }

    const from = message.from;
    const text = message.text.body;
    console.log(`Mensaje de ${from}: "${text}"`);

    const reply = await handleIncomingMessage(from, text);
    if (reply) {
      console.log(`Respuesta generada: "${reply}"`);
      await sendWhatsAppMessage(from, reply);
      console.log('Respuesta enviada por WhatsApp.');
    } else {
      console.warn(`Número no reconocido como cliente demo: ${from}`);
    }
  } catch (err) {
    console.error('Error procesando mensaje de WhatsApp:', err);
  }
});

// Endpoint de prueba local: misma lógica que el webhook, sin depender de Meta.
app.post('/test-chat', async (req, res) => {
  try {
    const { from, message } = req.body;
    if (!from || !message) return res.status(400).json({ error: 'Faltan "from" (teléfono) y/o "message" en el body' });

    const reply = await handleIncomingMessage(from, message);
    if (!reply) return res.status(404).json({ error: 'Ese teléfono no corresponde a ningún cliente de la demo' });

    res.json({ reply });
  } catch (err) {
    console.error('Error en /test-chat:', err);
    res.status(500).json({ error: err.message ?? 'Error interno' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor corriendo en http://localhost:${PORT}`);
});
