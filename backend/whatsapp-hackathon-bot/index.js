import './env.js';

import express from 'express';
import { sendWhatsAppMessage, sendWhatsAppList, sendWhatsAppButtons } from './whatsapp.js';
import { handleIncomingMessage } from './engine.js';

// Extrae el texto "hablado" por el cliente sin importar si escribió
// texto libre o tocó una opción de una lista/botón interactivo.
function extractIncomingText(message) {
  if (message.type === 'text') return message.text.body;
  if (message.type === 'interactive' && message.interactive?.list_reply) {
    const { id, title } = message.interactive.list_reply;
    return `Elige la opción "${title}" (código ${id}).`;
  }
  if (message.type === 'interactive' && message.interactive?.button_reply) {
    const { id, title } = message.interactive.button_reply;
    return `Elige la opción "${title}" (código ${id}).`;
  }
  return null;
}

async function deliverReply(to, result) {
  if (result.buttons && result.buttons.length > 0) {
    await sendWhatsAppButtons(to, result.text, result.buttons);
  } else if (result.list && result.list.rows.length > 0) {
    await sendWhatsAppList(to, result.text, 'Ver opciones', result.list.rows);
  } else {
    await sendWhatsAppMessage(to, result.text);
  }
}

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
    if (!message) {
      console.log('Payload sin mensaje (probablemente un status/delivery update); se ignora.');
      return;
    }

    const from = message.from;
    const text = extractIncomingText(message);
    if (!text) {
      console.log(`Tipo de mensaje no soportado (${message.type}); se ignora.`);
      return;
    }
    console.log(`Mensaje de ${from}: "${text}"`);

    let result;
    try {
      result = await handleIncomingMessage(from, text);
    } catch (err) {
      console.error('Error procesando mensaje de WhatsApp (con reintentos ya agotados):', err?.message ?? err);
      // El cliente nunca se queda sin respuesta, aunque el motor/Gemini haya fallado del todo.
      await sendWhatsAppMessage(from, 'Disculpe, tuvimos un problema técnico momentáneo. ¿Podría repetir su último mensaje, por favor? 🙏');
      return;
    }

    if (result) {
      const selector = result.buttons ? ` [botones: ${result.buttons.map((b) => b.id).join(', ')}]`
        : result.list ? ` [lista: ${result.list.rows.map((r) => r.id).join(', ')}]` : '';
      console.log(`Respuesta generada: "${result.text}"${selector}`);
      await deliverReply(from, result);
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

    const result = await handleIncomingMessage(from, message);
    if (!result) return res.status(404).json({ error: 'Ese teléfono no corresponde a ningún cliente de la demo' });

    res.json({ reply: result.text, list: result.list, buttons: result.buttons });
  } catch (err) {
    console.error('Error en /test-chat:', err);
    res.status(500).json({ error: err.message ?? 'Error interno' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor corriendo en http://localhost:${PORT}`);
});
