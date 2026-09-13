/**
 * Deja lista la llamada real por Twilio + ElevenLabs (NO compra nada):
 *   1. revisa la cuenta de Twilio (tiene que estar en pago, no Trial)
 *   2. habilita llamadas a El Salvador (Voice → Geographic Permissions)
 *   3. toma el número con voz que compraste en la consola de Twilio
 *   4. lo importa en ElevenLabs, le asigna el agente y escribe ELEVENLABS_PHONE_NUMBER_ID en .env
 * Uso: npx tsx apps/agent/src/scripts/setup-twilio-voice.ts
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import '../config.js';

const sid = process.env.TWILIO_ACCOUNT_SID ?? '';
const token = process.env.TWILIO_AUTH_TOKEN ?? '';
const xi = process.env.ELEVENLABS_API_KEY ?? '';
const agentId = process.env.ELEVENLABS_AGENT_ID ?? '';
const envPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../.env');
const auth = `Basic ${Buffer.from(`${sid}:${token}`).toString('base64')}`;
const mask = (n: string) => n.slice(0, -4) + '****';

async function twilio(url: string, init: RequestInit = {}) {
  const r = await fetch(url.startsWith('http') ? url : `https://api.twilio.com/2010-04-01/Accounts/${sid}${url}`, { ...init, headers: { Authorization: auth, ...(init.headers ?? {}) } });
  const j = (await r.json().catch(() => ({}))) as Record<string, any>;
  if (!r.ok) throw new Error(`Twilio ${r.status}: ${j.message ?? JSON.stringify(j)}`);
  return j;
}
async function eleven(url: string, init: RequestInit = {}) {
  const r = await fetch(`https://api.elevenlabs.io${url}`, { ...init, headers: { 'xi-api-key': xi, 'Content-Type': 'application/json', ...(init.headers ?? {}) } });
  const j = (await r.json().catch(() => ({}))) as any;
  if (!r.ok) throw new Error(`ElevenLabs ${r.status}: ${JSON.stringify(j.detail ?? j)}`);
  return j;
}
function setEnv(key: string, value: string) {
  const text = fs.readFileSync(envPath, 'utf8');
  const re = new RegExp(`^${key}=.*$`, 'm');
  fs.writeFileSync(envPath, re.test(text) ? text.replace(re, `${key}=${value}`) : `${text.trimEnd()}\n${key}=${value}\n`);
}

if (!sid || !token || !xi || !agentId) throw new Error('Faltan TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, ELEVENLABS_API_KEY o ELEVENLABS_AGENT_ID');

// 1. Cuenta
const account = await twilio('.json');
const balance = await twilio('/Balance.json');
console.log(`Twilio: ${account.type} · saldo ${balance.balance} ${balance.currency}`);
if (account.type === 'Trial') {
  console.log('❌ La cuenta sigue en Trial: Console → Admin → Account billing → Upgrade y carga saldo. Luego vuelve a correr esto.');
  process.exit(1);
}

// 2. Permiso para llamar a El Salvador
const country = (await twilio('https://voice.twilio.com/v1/DialingPermissions/Countries?IsoCode=SV')).content?.[0];
if (country?.low_risk_numbers_enabled) {
  console.log('✅ Llamadas a El Salvador ya habilitadas');
} else {
  await twilio('https://voice.twilio.com/v1/DialingPermissions/BulkCountryUpdates', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ UpdateRequest: JSON.stringify([{ iso_code: 'SV', low_risk_numbers_enabled: true, high_risk_special_numbers_enabled: false, high_risk_tollfraud_numbers_enabled: false }]) }),
  });
  console.log('✅ Habilité llamadas a El Salvador (números normales; tarificación especial sigue bloqueada)');
}

// 3. Número con voz (se compra en la consola)
const owned = ((await twilio('/IncomingPhoneNumbers.json')).incoming_phone_numbers ?? []) as Array<{ phone_number: string; capabilities: { voice: boolean } }>;
const number = owned.find((n) => n.capabilities?.voice)?.phone_number;
if (!number) {
  console.log('❌ No tienes números con voz: Console → Phone Numbers → Buy a number (United States, Voice). Luego vuelve a correr esto.');
  process.exit(1);
}
console.log(`Número de voz: ${mask(number)}`);

// 4. ElevenLabs: importar (o reutilizar) y asignar el agente
const list = (await eleven('/v1/convai/phone-numbers')) as Array<{ phone_number: string; phone_number_id: string }>;
const existing = list.find((p) => p.phone_number === number);
const phoneNumberId: string = existing?.phone_number_id
  ?? (await eleven('/v1/convai/phone-numbers', { method: 'POST', body: JSON.stringify({ provider: 'twilio', label: 'Cobranza preventiva', phone_number: number, sid, token }) })).phone_number_id;
await eleven(`/v1/convai/phone-numbers/${phoneNumberId}`, { method: 'PATCH', body: JSON.stringify({ agent_id: agentId }) });
setEnv('ELEVENLABS_PHONE_NUMBER_ID', phoneNumberId);
console.log(`✅ ${existing ? 'Ya estaba importado' : 'Importado'} en ElevenLabs, asignado al agente y ELEVENLABS_PHONE_NUMBER_ID escrito en .env`);
console.log('Siguiente: el agente se recarga solo; GET /health debe decir voice=elevenlabs, call_channel=phone');
process.exit(0);
