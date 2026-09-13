# Agente de voz — ElevenLabs + Gemini (implementado)

> Dueño: Josué · Código: `apps/agent` · BD: migración `20260912001200_prevention_engine.sql`

## Cómo funciona

```
Web "Iniciar corrida" ──POST /runs──► agente
   run_prevention (Supabase): recalcula riesgo y decide por cliente
   ├─ Grados C, D, E → LLAMADA
   │     ElevenLabs configurado + contact_enabled → llamada real (máx. max_calls_per_run)
   │     sin ElevenLabs → llamada SIMULADA con Gemini de cliente (máx. max_simulated_calls_per_run)
   │     no se puede llamar → correo de seguimiento
   ├─ Grados A, B → CORREO preventivo (recordatorio + link de pago + video)
   └─ Bloqueados / grupo de control / >30 días de atraso → no se contactan (o asesor humano)

Llamada real:
ElevenLabs (teléfono, voz, oído, turnos, interrupciones)
   └─ cada turno ──POST /v1/chat/completions──► agente
         Gemini 3.1 Flash-Lite + herramientas contra Supabase
         (validar_oferta · registrar_compromiso · enviar_por_correo · agendar_rellamada · escalar_a_humano · finalizar_llamada)
         supervisor en paralelo → evaluate_turn → etapa, ritmo, control
   └─ al colgar ──POST /webhooks/elevenlabs──► resultado, costo, correo de confirmación o de seguimiento
```

La política de canales está en `agent_policies` y se edita sin tocar código:
`channel_by_grade` (`voice` | `email` | `whatsapp` | `auto`), `email_fallback`, `max_calls_per_run`,
`max_simulated_calls_per_run`, `email_from`.

## Puesta en marcha

### 1. Base de datos (una vez)
1. Aplicar `supabase/migrations/20260912001200_prevention_engine.sql` (igual que las anteriores).
2. `select reset_demo();` → deja datos limpios y una corrida inicial.
3. Habilitar a quién se contacta DE VERDAD (los demás se simulan):
   ```sql
   select set_demo_contact('DEMO-001', '+503XXXXXXXX', 'tu-correo@dominio.com');   -- C/D: llamada
   select set_demo_contact('DEMO-003', '+503XXXXXXXX', 'tu-correo@dominio.com');   -- A: correo
   ```

### 2. Variables (`.env` de la raíz)

| Variable | Obligatoria | Para qué |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | ✅ ya están | BD |
| `GEMINI_API_KEY` | ✅ ya está | Cerebro del agente, supervisor, cliente simulado |
| `AGENT_SHARED_SECRET` | ✅ | Protege `/runs`, `/calls`, `/demo`. **La misma** en la web |
| `PUBLIC_WEB_URL` | recomendada | Base de links de pago y videos en correos (default `http://localhost:3001`) |
| `ELEVENLABS_API_KEY` | para llamadas reales | API de ElevenLabs |
| `ELEVENLABS_AGENT_ID` | para llamadas reales | Agente creado en el paso 3 |
| `ELEVENLABS_PHONE_NUMBER_ID` | para llamadas reales | Número importado de Twilio |
| `ELEVENLABS_WEBHOOK_SECRET` | para llamadas reales | Firma HMAC del webhook post-llamada |
| `CUSTOM_LLM_SECRET` | recomendada | ElevenLabs lo manda como `Authorization: Bearer …` a `/v1/chat/completions` |
| `RESEND_API_KEY` | para correos reales | Envío de correo |
| `EMAIL_FROM` | opcional | Sin dominio verificado usar `onboarding@resend.dev` (Resend solo entrega a tu propio correo) |
| `SIMULATE_CALLS` | opcional | `false` para no simular llamadas sin ElevenLabs |

Web (`web-banco/apps/dashboard/.env.local`): `AGENT_BASE_URL=http://localhost:3000` y `AGENT_SHARED_SECRET=<la misma>`.

### 3. ElevenLabs (panel)
1. **Twilio:** Upgrade (cuenta de pago) → comprar número de EE. UU. con Voice en la consola → `npx tsx apps/agent/src/scripts/setup-twilio-voice.ts` (habilita llamadas a El Salvador, importa el número en ElevenLabs, le asigna el agente y escribe `ELEVENLABS_PHONE_NUMBER_ID`). Twilio no vende números de El Salvador por API; el de EE. UU. llama a SV sin problema.
2. **URL pública del agente:** `ngrok http 3000` (hay `NGROK_AUTH_TOKEN` en `.env`) o deploy en Railway.
3. **Crear agente** → copiar el ID a `ELEVENLABS_AGENT_ID`:
   - Idioma: **Español**. Voz: elegir una latina y probarla.
   - **Primer mensaje:** `Buenos días, {{nombre}}. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con {{nombre_completo}}?`
   - **System prompt** (solo identificadores; el prompt real lo arma el servidor desde Supabase):
     ```
     CONVERSATION_ID={{conversation_id}}
     EL_CONVERSATION={{system__conversation_id}}
     ```
   - **Valores de prueba de las variables:** `nombre=Carlos`, `nombre_completo=Carlos Martínez Aguilar`, `conversation_id` vacío.
     Así el botón "Probar agente" del panel crea una conversación simulada con `TEST_CUSTOMER_CODE` (DEMO-001).
   - **LLM:** *Custom LLM* → URL `https://<tu-url-publica>/v1` (el servidor acepta `/v1/chat/completions` y `/chat/completions`).
     API key: un secreto con el mismo valor que `CUSTOM_LLM_SECRET`.
   - **Herramientas del sistema:** activar **End call**.
   - **Turnos:** interrupciones activadas; timeout de silencio ~6 s.
4. **Webhooks** (*Settings → Webhooks*): `post_call_transcription` y `call_initiation_failure` → `https://<tu-url-publica>/webhooks/elevenlabs`. Copiar el secreto a `ELEVENLABS_WEBHOOK_SECRET`.

### 4. Probar (en este orden)

```bash
npm run agent:dev                                                     # servidor :3000
curl localhost:3000/health                                           # qué proveedores están activos
npx tsx apps/agent/src/scripts/test-custom-llm.ts DEMO-003          # endpoint Custom LLM (SSE) como lo llama ElevenLabs
npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-001 ESC-C      # llamada simulada completa con guion
npx tsx apps/agent/src/scripts/simulate-call.ts DEMO-002            # cliente interpretado por Gemini
curl -X POST localhost:3000/calls/<customer_id> -H "x-agent-secret: $AGENT_SHARED_SECRET" -H 'Content-Type: application/json' -d '{}'   # llamar a uno
```
Luego en la web: **Iniciar corrida** → **En vivo**.

## Qué está verificado y qué no

| Pieza | Estado |
|---|---|
| Motor de turnos + tools + supervisor contra Supabase y Gemini reales | ✅ Probado: etapas APERTURA→COMPROMISO, compromiso con recibo, cierre |
| Endpoint Custom LLM (SSE formato OpenAI, `end_call`) | ✅ Probado por HTTP |
| Tercero al teléfono: no revela datos y cuelga | ✅ Probado |
| Migración 1200: corrida, política C–E/A–B, simulación, planes, videos | ✅ 71 pruebas en Postgres local |
| Llamada real con ElevenLabs + Twilio | ⏳ Falta configurar las claves |
| Webhook firmado de ElevenLabs | ⏳ Implementado con el SDK oficial; falta evento real |
| Correo real con Resend | ⏳ Falta `RESEND_API_KEY` |
| `POST /runs` de punta a punta | ⏳ Falta aplicar la migración 1200 en Supabase |

**Latencia honesta:** Gemini tarda 0.7–2.4 s al primer token (medido), y a eso se suma el STT/TTS de ElevenLabs.
El P95 < 2 s no está garantizado: se mide en `messages.latency_ms` con llamadas reales.

## Modelos
`gemini-2.5-flash-lite` **ya no está disponible para cuentas nuevas** (verificado 12/09/2026). La migración 1200 lo marca
retirado y usa `gemini-3.1-flash-lite` para el cerebro, el supervisor y el cliente simulado. El código también lo remapea.
