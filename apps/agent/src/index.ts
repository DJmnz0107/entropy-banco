import 'dotenv/config';
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { WebSocketServer } from 'ws';
import { setupVoiceWs } from './routes/voice.js';
import { healthRouter } from './routes/health.js';
import { demoRouter } from './routes/demo.js';

const app = new Hono();

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
