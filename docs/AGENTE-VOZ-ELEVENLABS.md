# Mi parte — Agente de voz con ElevenLabs

> Dueño: Josué · Depende de: Supabase (listo) · Lo consume: Web (Centro de Prevención) y WhatsApp (handoffs)
> Marcas: ✅ existe hoy · 🆕 lo agrega la migración 1200 (Motor de Prevención) · ⚠️ verificar en la doc de ElevenLabs

## 0. Qué cambia y qué NO cambia

**Cambia:** la voz deja de ser Gemini Live por WebSocket. **ElevenLabs Agents** se encarga de telefonía, STT, TTS,
turnos, interrupciones y llamadas por lotes (la "corrida").

**NO cambia:** el cerebro. Las reglas, el controlador de etapas, la validación de ofertas y los compromisos siguen en
Supabase. De `apps/agent` se reutiliza `lib/supabase.ts`, `lib/supervisor.ts` y la lógica de tools de `voice/session.ts`.

**Por qué ElevenLabs resuelve tus bloqueadores actuales:**

| Bloqueador con Gemini Live | Con ElevenLabs |
|---|---|
| B1 · No hay cliente de navegador | Llamada telefónica real (el teléfono suena en el escenario) o widget web para probar |
| B2/B4 · Transcripciones apagadas o en fragmentos | ElevenLabs entrega el historial completo por turno |
| B3 · Inyectar control interrumpe al modelo | Tu servidor **es** el LLM: el control se aplica antes de generar cada respuesta |
| Interrupciones / buffer de audio | Los maneja la plataforma |
| "Corrida" de llamadas | Batch calling nativo |

## 1. Arquitectura elegida: ElevenLabs + Custom LLM (tu servidor)

```
Web "Iniciar corrida" ─► RPC run_prevention 🆕 ─► lista priorizada + plan por cliente
        │
        ▼
POST /runs/:id/dispatch  (tu servidor)
   ├─ por cada cliente contactable: start_conversation ✅ → conversation_id
   └─ ElevenLabs: batch call / outbound call con dynamic variables {conversation_id, nombre, …}
                                   │
                  ┌────────────────┴─────────────────┐
                  ▼                                  │
      ElevenLabs Agent (voz, STT, turnos,            │
      interrupciones, telefonía)                     │
                  │ cada turno                       │
                  ▼                                  │
POST /v1/chat/completions  (TU SERVIDOR = Custom LLM, SSE)
   1. identifica conversation_id
   2. log_message(customer) ✅
   3. aplica el último control_message (evaluate_turn del turno anterior)
   4. Gemini Flash-Lite genera la respuesta con tools INTERNAS:
        validate_offer / register_commitment / create_handoff / request_escalation ✅
   5. stream del texto a ElevenLabs  (+ end_call si la etapa es terminal)
   6. en paralelo: supervisor → evaluate_turn ✅ → control para el siguiente turno
                  │
                  ▼ al colgar
POST /webhooks/elevenlabs  (post_call_transcription · call_initiation_failure)
   → end_conversation ✅ · record_model_usage ✅ · handoff a WhatsApp si aplica
```

**Por qué Custom LLM y no el LLM integrado de ElevenLabs:**
1. **Control duro:** las tools se ejecutan en tu servidor contra Supabase. ElevenLabs nunca ve una oferta que la BD no autorizó.
2. **Pantalla "Intervención en vivo":** ElevenLabs solo documenta webhooks **post-llamada**, no eventos durante la llamada.
   Si tu servidor recibe cada turno, escribe en Supabase en tiempo real y la web lo muestra con Realtime.
3. **Mismo cerebro que WhatsApp.**

**Plan B** (si Custom LLM se complica, *máx. 3 h de intento*): LLM integrado de ElevenLabs + *server tools* (webhooks a tu
servidor para validar y registrar) + webhook post-llamada para guardar la transcripción. Se pierde la vista en vivo
turno a turno, pero la llamada funciona.

## 2. Cuentas y configuración (día 1, ~1 h)

- [ ] **ElevenLabs:** cuenta y plan con minutos de Agents (costo de referencia: ~$0.08–0.10/min en fuentes secundarias, verificar en tu plan).
- [ ] **Twilio:** comprar un número y **pasar la cuenta a pago**. ⚠️ En modo trial solo se llama a números verificados y puede reproducirse un aviso de cuenta de prueba al contestar; eso arruina la demo.
- [ ] **Importar el número de Twilio en ElevenLabs** (integración nativa) ⚠️.
- [ ] **URL pública estable** para tu servidor: Railway/Render, o ngrok con dominio reservado. La latencia importa: no uses un túnel lento.
- [ ] Probar una llamada a **tu propio celular** desde el panel de ElevenLabs con el LLM integrado (valida número, voz y audio).
- [ ] `.env` del agente:
  ```env
  ELEVENLABS_API_KEY=
  ELEVENLABS_AGENT_ID=
  ELEVENLABS_PHONE_NUMBER_ID=
  ELEVENLABS_WEBHOOK_SECRET=          # HMAC de webhooks
  CUSTOM_LLM_SHARED_SECRET=           # header que ElevenLabs envía a tu /v1/chat/completions
  GEMINI_API_KEY=
  SUPERVISOR_MODEL_KEY=supervisor.gemini-2.5-flash-lite   # perfil de la BD, no ID hardcodeado
  COMPOSER_MODEL_KEY=composer.gemini-3.1-flash-lite
  PUBLIC_BASE_URL=https://<tu-servidor>
  ```

## 3. Configurar el agente en ElevenLabs (~1 h)

- [ ] **Idioma:** español. **Voz:** probar 3 voces latinoamericanas con la misma frase de apertura y elegir en equipo.
- [ ] **Primer mensaje** (dynamic variables):
  `Buenos días, {{nombre}}. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con {{nombre_completo}}?`
  → Dice que es asistente digital (política) y **no menciona el crédito antes de confirmar identidad**.
- [ ] **System prompt en ElevenLabs:** mínimo, solo para que tu servidor identifique la conversación:
  ```
  CONVERSATION_ID={{conversation_id}}
  ```
  Tu servidor reemplaza este prompt por el construido desde Supabase (paso 4.2).
  ⚠️ Verificar que los `{{dynamic_variables}}` llegan sustituidos en `messages[0]` del Custom LLM.
  Si no llegan, usar `elevenlabs_extra_body`.
- [ ] **LLM:** Custom LLM → `https://<tu-servidor>/v1/chat/completions`, con el secreto como header.
- [ ] **Turnos / interrupciones:** interrupciones **activadas**; timeout de silencio ~6 s (coincide con `interruption_policy.silence_reprompt_ms`).
- [ ] **System tools:** `end_call` activado. Opcional: `transfer_to_number` si hay un asesor real para escalar.
- [ ] **Webhooks post-llamada:** `post_call_transcription` y `call_initiation_failure` → `https://<tu-servidor>/webhooks/elevenlabs`.

## 4. Refactor de `apps/agent` (~4–5 h)

### 4.1 Qué se queda, qué se va, qué se agrega

```
apps/agent/src/
  lib/supabase.ts          ✅ se queda (agregar wrappers nuevos 🆕)
  lib/supervisor.ts        ✅ se queda — cambiar: modelo desde perfil de BD + timeout 2.5 s + criterios de la etapa
  lib/gemini-live.ts       ❌ se elimina
  routes/voice.ts (WS)     ❌ se elimina
  voice/session.ts         ♻️ se divide en:
  llm/chat-completions.ts  🆕 POST /v1/chat/completions (SSE)
  llm/turn-state.ts        🆕 estado por conversation_id (control pendiente, última oferta, flags)
  llm/tools.ts             🆕 tools internas → RPC (reutiliza handleFunctionCall de session.ts)
  llm/prompt.ts            🆕 prompt desde get_conversation_context + etapa actual (sin guiones hardcodeados)
  routes/runs.ts           🆕 POST /runs/:id/dispatch · POST /calls/:customer_id (llamar a uno)
  routes/webhooks.ts       🆕 POST /webhooks/elevenlabs (HMAC)
  lib/elevenlabs.ts        🆕 cliente: outbound call, batch call, estado
```

### 4.2 `POST /v1/chat/completions`: algoritmo por turno

```ts
// 0. Seguridad: validar header secreto. Responder SIEMPRE en SSE (text/event-stream).
// 1. conversation_id ← regex sobre messages[0].content ("CONVERSATION_ID=…")
// 2. state = turnState.get(conversation_id)   // en memoria; si no existe, cargar start result de Supabase
// 3. lastUser = último mensaje role=user (lo que dijo el cliente)
//    log_message(conv, 'customer', lastUser)  → message_id
// 4. prompt = buildPrompt(state.context, state.currentStage, state.pendingControl)
//       - datos del cliente, perfil financiero 🆕, "por qué lo contactamos" 🆕
//       - etapa actual con SUS instrucciones desde la BD (no hardcodear guiones)
//       - ofertas permitidas (máx. 3) y el control_message pendiente
// 5. Gemini Flash-Lite (temp 0.3, max ~120 tokens, stream) con tools internas:
//       validar_oferta, registrar_compromiso, enviar_whatsapp, escalar
//    - Si pide una tool: emitir ANTES un buffer "Permítame revisar... " (con "... " al final; ver doc Custom LLM)
//      ejecutar RPC → devolver resultado a Gemini → seguir generando
// 6. Stream de texto a ElevenLabs. Al terminar: log_message(conv, 'agent', texto, {latency_ms, ttfb_ms, model_profile_key})
// 7. Si state.terminal: emitir tool call de sistema end_call con el mensaje de despedida
// 8. En paralelo (no bloquea): scorecard = supervisor(...); ev = evaluate_turn(conv, scorecard, message_id)
//       state.pendingControl = ev.control_message; state.currentStage = ev.to_stage
//       if ev.is_terminal → state.terminal = true (se cierra con despedida en el SIGUIENTE turno, no se corta)
```

**Reglas del turno:**
- **Latencia objetivo:** primer token < 800 ms en tu endpoint. Medir `ttfb_ms` y guardarlo (P95 del dashboard).
- **Nunca** esperar al supervisor para responder. El control va un turno atrasado; la protección dura está en las RPC.
- `registrar_compromiso` solo con `customer_confirmed=true` y después de `validar_oferta`. Si la BD responde
  `CONDICIONES_INTERRUMPIDAS`, repetir las condiciones.
- **No leer URLs en voz alta.** El link se envía por WhatsApp con `create_handoff('whatsapp','SEND_PAYMENT_LINK')`.
- Fechas: el cliente dice "el viernes" → resolver en código con `America/El_Salvador` → `YYYY-MM-DD`.

### 4.3 Interrupciones con ElevenLabs

ElevenLabs corta el audio cuando el cliente habla. Lo que tu servidor debe hacer:
- [ ] ⚠️ **Verificar en la primera prueba** si el historial que llega en el siguiente turno trae el mensaje del agente
  **truncado** (lo que alcanzó a sonar) o completo. Guardar ambos textos en `meta` y comparar.
- [ ] Si llega truncado y el turno anterior contenía condiciones de oferta → `log_interruption(conv, 'real', msg_id, heard_text, …, offer_code)`.
  La BD bloqueará el registro hasta que se repitan.
- [ ] Si el cliente solo dijo "ajá/mjm" (lista en `interruption_policy.backchannel_phrases`) → `log_interruption('backchannel')` y seguir.
- [ ] Silencio: si ElevenLabs manda turno vacío o timeout → `log_silence` → usar su `control_message`.

### 4.4 La "corrida": `POST /runs/:id/dispatch`

```ts
// 1. run = rpc('get_prevention_run', {p_run_id}) 🆕 → intervenciones con next_best_intervention.channel = 'voice'
// 2. Para cada cliente:
//      if (!contact_enabled) → marcar "simulada" (NO se llama: teléfonos +50300… no enrutables)
//      else start_conversation(customer_id, 'voice', 'outbound', null, null, intervention_id)  ← SIN p_force
// 3. ElevenLabs:
//      - 1 cliente (botón "Empezar llamada") → outbound call
//      - varios → batch call con dynamic variables por destinatario:
//        phone_number, conversation_id, nombre, nombre_completo, grado, monto_text, fecha_text
// 4. Guardar el id de ElevenLabs en conversations.external_id
// 5. Responder a la web {llamadas_reales, simuladas, errores}
```
⚠️ Revisar en la API los nombres exactos de los endpoints de outbound y batch calls. La doc confirma que el batch acepta
variables por destinatario, se puede programar, reporta estado por llamada y funciona con Twilio nativo o SIP.

**Seguridad de la demo:** solo se llama a clientes con `contact_enabled = true`. Antes de ensayar:
`select reset_demo();` y luego `select set_demo_contact('DEMO-001','+503…');`.

### 4.5 `POST /webhooks/elevenlabs`

- [ ] Verificar la firma HMAC (header `elevenlabs-signature`) con el SDK (`constructEvent`).
- [ ] `post_call_transcription`:
  - conversation_id ← `conversation_initiation_client_data.dynamic_variables.conversation_id`
  - reconciliar la transcripción: insertar solo los turnos que falten (tu servidor ya registró la mayoría)
  - `record_model_usage(conv, 'voice.elevenlabs', {audio_in_seconds, audio_out_seconds, …})` con costo y duración de `metadata`
  - `end_conversation(conv, outcome)`, con outcome = el sugerido por la última etapa terminal o, si hay compromiso, el mapeo por oferta
  - si hubo compromiso con pago → `create_handoff(conv,'whatsapp','SEND_PAYMENT_LINK')` (si no se hizo durante la llamada)
- [ ] `call_initiation_failure` (`busy` / `no-answer`) → `end_conversation(conv,'NO_ANSWER')` + `create_handoff(conv,'whatsapp','FOLLOW_UP_MESSAGE')`
  → **continuidad omnicanal:** si no contesta, le llega WhatsApp.
- [ ] Idempotencia: ElevenLabs puede reintentar; `end_conversation` ya es idempotente.

### 4.6 Correcciones del código actual que se arrastran

- [ ] Quitar `p_force: true` por defecto. Si no, se llama a Rosa (disputa) y a Miguel (control).
- [ ] `registrar_rellamada`: usar el código `REAGENDAR`, no `CALLBACK`.
- [ ] Supervisor: modelo desde `ai_model_profiles` (Flash-Lite), `AbortController` de 2.5 s y fallback seguro.
- [ ] Guardar `latency_ms`/`ttfb_ms` en cada mensaje del agente.
- [ ] Borrar `routes/voice.ts` y `lib/gemini-live.ts` una vez que funcione la primera llamada con ElevenLabs.
- [ ] Nuevo perfil en la BD `voice.elevenlabs` (lo agrega la migración 1200 🆕).

## 5. Pruebas (en este orden)

| # | Prueba | Criterio de éxito |
|---|---|---|
| 1 | Llamada a tu celular con LLM integrado | Suena, voz natural en español |
| 2 | Custom LLM "eco" (responde fijo) | ElevenLabs habla el texto de tu servidor; `ttfb_ms` < 800 |
| 3 | DEMO-001 Carlos, escenario **C (dificultad)** | Etapas APERTURA→…→CONFIRMACION en `turn_evaluations`; compromiso con `receipt_code` |
| 4 | **H (interrumpe durante condiciones)** | La BD rechaza `CONDICIONES_INTERRUMPIDAS`; el agente repite y registra |
| 5 | D (molesto) → escalamiento | Se despide antes de colgar; escalación creada |
| 6 | K (tercero) | No menciona crédito ni monto |
| 7 | No contesta | `NO_ANSWER` + WhatsApp de seguimiento |
| 8 | Corrida con 3 teléfonos del equipo | Web muestra 3 llamadas en vivo; resto "simuladas" |
| 9 | **Grabar video de respaldo** de la prueba 3 + 4 | Por si falla la red en el escenario |

## 6. Definición de "terminado" para mi parte

- [ ] Botón "Empezar llamada" de la web hace sonar mi celular en < 10 s.
- [ ] Cada turno aparece en Supabase en < 2 s (la web lo ve en vivo).
- [ ] Etapa, intención, sentimiento, acción y latencia visibles durante la llamada.
- [ ] Compromiso registrado solo con recibo; interrupción durante condiciones bloqueada por la BD.
- [ ] Al colgar: resultado, costo, duración y handoff a WhatsApp.
- [ ] Corrida: llama solo a contactables, simula el resto, respeta bloqueos y grupo de control.
- [ ] P95 de respuesta medido y visible (valor real, no estimado).

## 7. Riesgos de mi parte

| Riesgo | Mitigación |
|---|---|
| Latencia extra por el salto a tu servidor | Flash-Lite, `max_tokens` bajo, contexto en memoria, supervisor asíncrono, buffer words |
| Dynamic variables no llegan al Custom LLM | Plan: `elevenlabs_extra_body` o mapear por número de teléfono |
| Twilio trial / costo de llamadas a SV | Cuenta de pago; llamar solo a 2–3 números del equipo |
| Custom LLM consume demasiado tiempo | Plan B en 3 h: LLM integrado + server tools + webhook |
| Servidor caído en la demo | Deploy en Railway (no laptop); video de respaldo |
