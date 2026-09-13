import { assertCoreConfig, config, providers } from './config.js';
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { healthRouter } from './routes/health.js';
import { demoRouter } from './routes/demo.js';
import { runsRouter } from './routes/runs.js';
import { llmRouter } from './routes/llm.js';
import { webhooksRouter } from './routes/webhooks.js';

assertCoreConfig();

const app = new Hono();
app.use('*', cors());

app.get('/', (c) => c.json({
  service: '@entropy/agent',
  status: 'online',
  providers: { voice: providers.voice(), email: providers.email() },
  endpoints: {
    health: 'GET /health',
    run: 'POST /runs  (x-agent-secret)',
    dispatch: 'POST /runs/:runId/dispatch  (x-agent-secret)',
    call: 'POST /calls/:customerId  (x-agent-secret)',
    custom_llm: 'POST /v1/chat/completions  (ElevenLabs Custom LLM)',
    webhook: 'POST /webhooks/elevenlabs',
  },
}));

// Meta WhatsApp webhook → se reenvía al bot de WhatsApp (backend/whatsapp-hackathon-bot, puerto 3002).
// Así ngrok expone UNA sola URL para ElevenLabs (agente) y Meta (bot).
app.all('/webhook', async (c) => {
  const target = new URL(c.req.url);
  const url = `${config.whatsappBotUrl}/webhook${target.search}`;
  try {
    const res = await fetch(url, {
      method: c.req.method,
      headers: { 'Content-Type': c.req.header('content-type') ?? 'application/json' },
      body: c.req.method === 'GET' ? undefined : await c.req.text(),
    });
    return new Response(await res.text(), { status: res.status, headers: { 'Content-Type': res.headers.get('content-type') ?? 'text/plain' } });
  } catch (err) {
    console.warn(`[webhook] bot de WhatsApp no disponible en ${config.whatsappBotUrl}: ${(err as Error).message}`);
    // Meta reintenta si no respondemos 200; mejor avisar que el bot está caído
    return c.text('WhatsApp bot unavailable', 502);
  }
});

app.route('/health', healthRouter);
app.route('/demo', demoRouter);
app.route('/', runsRouter);
app.route('/', llmRouter);
app.route('/', webhooksRouter);

serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`[agent] http://localhost:${info.port} · voz=${providers.voice()} · correo=${providers.email()}`);
  if (providers.voice() === 'simulated') console.log('[agent] Sin ElevenLabs: las llamadas de la corrida se simulan con Gemini.');
  if (providers.email() === 'simulated') console.log('[agent] Sin RESEND_API_KEY: los correos se registran pero no se envían.');
});
