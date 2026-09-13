/** Revisión SOLO LECTURA de la configuración de WhatsApp Cloud API (Meta). */
import '../config.js';
const tok = process.env.META_ACCESS_TOKEN, pnid = process.env.META_PHONE_NUMBER_ID, waba = process.env.META_WABA_ID;
const g = 'https://graph.facebook.com/v21.0';
async function get(path: string) {
  const r = await fetch(`${g}/${path}`, { headers: { Authorization: `Bearer ${tok}` } });
  const j = (await r.json()) as Record<string, unknown> & { error?: { message: string } };
  return j.error ? { error: j.error.message } : j;
}
const num = (await get(`${pnid}?fields=display_phone_number,verified_name,quality_rating,platform_type,code_verification_status,name_status,account_mode`)) as Record<string, string>;
if (num.display_phone_number) num.display_phone_number = num.display_phone_number.slice(0, -4) + '****';
console.log('NÚMERO:', num);
console.log('LLAMADAS (settings):', JSON.stringify(await get(`${pnid}/settings`)));
const tpl = (await get(`${waba}/message_templates?fields=name,status,language,category,components&limit=50`)) as { data?: Array<{ name: string; language: string; status: string; category: string; components: Array<{ type: string }> }> };
console.log('PLANTILLAS:', tpl.data ? tpl.data.map((t) => `${t.name} (${t.language}, ${t.status}, ${t.category}, [${t.components.map((c) => c.type).join(',')}])`) : tpl);
console.log('WABA:', await get(`${waba}?fields=name,account_review_status,business_verification_status,ownership_type`));
process.exit(0);
