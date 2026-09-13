/**
 * Configuración del agente. Todo lo que falte se degrada a modo simulado,
 * nunca a un error silencioso.
 */
import 'dotenv/config';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

// .env de la raíz del monorepo (apps/agent/src → ../../..)
dotenv.config({ path: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../.env') });

function env(name: string): string | undefined {
  const value = process.env[name];
  return value && value.trim() !== '' ? value.trim() : undefined;
}

export const config = {
  port: Number(env('PORT') ?? 3000),

  supabaseUrl: env('SUPABASE_URL'),
  supabaseServiceKey: env('SUPABASE_SERVICE_ROLE_KEY') ?? env('SUPABASE_SECRET_KEY'),

  geminiApiKey: env('GEMINI_API_KEY'),
  geminiBaseUrl: env('GEMINI_OPENAI_BASE_URL') ?? 'https://generativelanguage.googleapis.com/v1beta/openai/',

  elevenlabs: {
    apiKey: env('ELEVENLABS_API_KEY'),
    agentId: env('ELEVENLABS_AGENT_ID'),
    phoneNumberId: env('ELEVENLABS_PHONE_NUMBER_ID'),                 // solo si se usara telefonía (Twilio/SIP)
    /** WhatsApp importado en ElevenLabs (panel → WhatsApp → Import account). Es el canal de llamadas que usamos. */
    whatsappPhoneNumberId: env('ELEVENLABS_WHATSAPP_PHONE_NUMBER_ID'),
    /** Plantilla de Meta con componente "call permission request" (aprobada en WhatsApp Manager). */
    whatsappCallPermissionTemplate: env('WHATSAPP_CALL_PERMISSION_TEMPLATE'),
    whatsappCallPermissionTemplateLang: env('WHATSAPP_CALL_PERMISSION_TEMPLATE_LANG') ?? 'es',
    webhookSecret: env('ELEVENLABS_WEBHOOK_SECRET'),
  },
  customLlmSecret: env('CUSTOM_LLM_SECRET'),

  resend: {
    apiKey: env('RESEND_API_KEY'),
    from: env('EMAIL_FROM'),
  },

  /** Secreto que la web manda en `x-agent-secret` para iniciar corridas. */
  agentSharedSecret: env('AGENT_SHARED_SECRET'),
  /** Bot de WhatsApp (Meta Cloud API) al que se reenvía /webhook: una sola URL pública para agente + bot. */
  whatsappBotUrl: (env('WHATSAPP_BOT_URL') ?? 'http://localhost:3002').replace(/\/$/, ''),
  /** Base pública de la web (links de pago y videos). */
  publicWebUrl: (env('PUBLIC_WEB_URL') ?? 'http://localhost:3001').replace(/\/$/, ''),

  /** Sin ElevenLabs, las llamadas de la corrida se simulan con Gemini (cliente simulado). */
  simulateCallsWhenNoVoiceProvider: (env('SIMULATE_CALLS') ?? 'true') !== 'false',
  /** Permite probar el agente desde el panel de ElevenLabs sin corrida (crea conversación simulada). */
  allowTestConversations: (env('ALLOW_TEST_CONVERSATIONS') ?? 'true') !== 'false',
  testCustomerCode: env('TEST_CUSTOMER_CODE') ?? 'DEMO-001',
};

export const providers = {
  voice: (): 'elevenlabs' | 'simulated' =>
    config.elevenlabs.apiKey && config.elevenlabs.agentId && (callChannel() !== null) ? 'elevenlabs' : 'simulated',
  email: (): 'resend' | 'simulated' => (config.resend.apiKey ? 'resend' : 'simulated'),
};

/** Canal por el que ElevenLabs hace la llamada real: WhatsApp (preferido) o telefonía. */
export function callChannel(): 'whatsapp' | 'phone' | null {
  if (config.elevenlabs.whatsappPhoneNumberId && config.elevenlabs.whatsappCallPermissionTemplate) return 'whatsapp';
  if (config.elevenlabs.phoneNumberId) return 'phone';
  return null;
}

export function assertCoreConfig(): void {
  const missing = [
    !config.supabaseUrl && 'SUPABASE_URL',
    !config.supabaseServiceKey && 'SUPABASE_SERVICE_ROLE_KEY',
    !config.geminiApiKey && 'GEMINI_API_KEY',
  ].filter(Boolean);
  if (missing.length) throw new Error(`[config] Faltan variables obligatorias: ${missing.join(', ')}`);
}
