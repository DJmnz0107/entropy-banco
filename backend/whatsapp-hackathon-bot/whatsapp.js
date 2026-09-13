import axios from 'axios';

const GRAPH_API_VERSION = 'v21.0';

function graphUrl() {
  return `https://graph.facebook.com/${GRAPH_API_VERSION}/${process.env.META_PHONE_NUMBER_ID}/messages`;
}

function authHeaders() {
  return {
    Authorization: `Bearer ${process.env.META_ACCESS_TOKEN}`,
    'Content-Type': 'application/json',
  };
}

export async function sendWhatsAppMessage(to, text) {
  await axios.post(
    graphUrl(),
    {
      messaging_product: 'whatsapp',
      to,
      type: 'text',
      text: { body: text },
    },
    { headers: authHeaders() }
  );
}

// buttons: [{ id, title }] — máximo 3 (límite de WhatsApp), título ≤ 20 caracteres.
// El cliente toca uno y WhatsApp manda de vuelta interactive.button_reply.{id,title}.
export async function sendWhatsAppButtons(to, bodyText, buttons) {
  await axios.post(
    graphUrl(),
    {
      messaging_product: 'whatsapp',
      to,
      type: 'interactive',
      interactive: {
        type: 'button',
        body: { text: bodyText },
        action: {
          buttons: buttons.slice(0, 3).map((b) => ({
            type: 'reply',
            reply: { id: b.id, title: b.title.slice(0, 20) },
          })),
        },
      },
    },
    { headers: authHeaders() }
  );
}

// rows: [{ id, title, description }] — máximo 10 (límite de WhatsApp).
// Cuando el cliente toca una fila, WhatsApp manda de vuelta un mensaje
// type "interactive" con interactive.list_reply.{id,title}.
export async function sendWhatsAppList(to, bodyText, buttonLabel, rows) {
  await axios.post(
    graphUrl(),
    {
      messaging_product: 'whatsapp',
      to,
      type: 'interactive',
      interactive: {
        type: 'list',
        body: { text: bodyText },
        action: {
          button: buttonLabel.slice(0, 20),
          sections: [
            {
              title: 'Opciones',
              rows: rows.slice(0, 10).map((r) => ({
                id: r.id,
                title: r.title.slice(0, 24),
                description: (r.description ?? '').slice(0, 72),
              })),
            },
          ],
        },
      },
    },
    { headers: authHeaders() }
  );
}
