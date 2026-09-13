import { Hono } from 'hono';
import { config, providers } from '../config.js';

export const healthRouter = new Hono();

healthRouter.get('/', (c) => c.json({
  status: 'ok',
  service: '@entropy/agent',
  timestamp: new Date().toISOString(),
  providers: { voice: providers.voice(), email: providers.email(), llm: config.geminiApiKey ? 'gemini' : 'missing' },
  configured: {
    supabase: !!config.supabaseUrl && !!config.supabaseServiceKey,
    gemini: !!config.geminiApiKey,
    elevenlabs_api_key: !!config.elevenlabs.apiKey,
    elevenlabs_agent_id: !!config.elevenlabs.agentId,
    elevenlabs_phone_number_id: !!config.elevenlabs.phoneNumberId,
    elevenlabs_webhook_secret: !!config.elevenlabs.webhookSecret,
    custom_llm_secret: !!config.customLlmSecret,
    resend: !!config.resend.apiKey,
    agent_shared_secret: !!config.agentSharedSecret,
  },
}));
