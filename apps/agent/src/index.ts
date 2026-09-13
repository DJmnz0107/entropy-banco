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

// Meta WhatsApp webhook (verificación + recepción) — lo usa el bot de WhatsApp
app.get('/webhook', (c) => {
  const mode = c.req.query('hub.mode');
  const token = c.req.query('hub.verify_token');
  const challenge = c.req.query('hub.challenge');
  if (mode === 'subscribe' && token === (process.env.META_VERIFY_TOKEN ?? '')) return c.text(challenge ?? '');
  return c.text('Forbidden', 403);
});
app.post('/webhook', async (c) => {
  const body = await c.req.json().catch(() => null);
  console.log('[webhook] Meta event:', JSON.stringify(body));
  return c.text('EVENT_RECEIVED', 200);
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
