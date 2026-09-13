import 'dotenv/config';
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { WebSocketServer } from 'ws';
import { setupVoiceWs } from './routes/voice.js';
import { healthRouter } from './routes/health.js';
import { demoRouter } from './routes/demo.js';

import { cors } from 'hono/cors';

const app = new Hono();

// Enable CORS for all origins (Next.js dashboard, browser, tools)
app.use('*', cors());

// Root endpoint
app.get('/', (c) => {
  return c.json({
    service: '@entropy/agent',
    status: 'online',
    voice_ws: '/ws/voice/:customer_id',
    health: '/health',
    demo: '/demo/customers',
  });
});

// Meta WhatsApp Webhook verification
app.get('/webhook', (c) => {
  const mode = c.req.query('hub.mode');
  const token = c.req.query('hub.verify_token');
  const challenge = c.req.query('hub.challenge');

  const verifyToken = process.env.META_VERIFY_TOKEN ?? 'tokenPrivadoHackathonBA';

  if (mode === 'subscribe' && token === verifyToken) {
    console.log('[webhook] Meta webhook verified successfully!');
    return c.text(challenge ?? '');
  }

  return c.text('Forbidden', 403);
});

// Meta WhatsApp Webhook event receiver
app.post('/webhook', async (c) => {
  try {
    const body = await c.req.json();
    console.log('[webhook] Incoming Meta event:', JSON.stringify(body, null, 2));
    return c.text('EVENT_RECEIVED', 200);
  } catch (err) {
    console.error('[webhook] Error parsing incoming event:', err);
    return c.text('EVENT_RECEIVED', 200);
  }
});

// Routes
app.route('/health', healthRouter);
app.route('/demo', demoRouter);

const port = parseInt(process.env.PORT ?? '3000', 10);

const server = serve({ fetch: app.fetch, port }, (info) => {
  console.log(`[agent] Voice agent running on http://localhost:${info.port}`);
  console.log(`[agent] WS endpoint: ws://localhost:${info.port}/ws/voice/:customer_id`);
});

const wss = new WebSocketServer({ server: server as any });
setupVoiceWs(wss);
