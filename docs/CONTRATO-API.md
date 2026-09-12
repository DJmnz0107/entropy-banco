# Contrato de la base de datos — Voz · WhatsApp · Web

La base de datos **es** el backend compartido. La lógica de negocio (riesgo, reglas,
control de etapas, validación de ofertas, compromisos) vive en funciones de Postgres
que los tres equipos llaman igual:

```ts
// JS / TS
const { data, error } = await supabase.rpc('evaluate_turn', { p_conversation_id, p_scorecard })
```
```python
# Python
supabase.rpc("evaluate_turn", {"p_conversation_id": cid, "p_scorecard": sc}).execute()
```

> **Regla de oro:** el LLM propone, estas funciones autorizan y escriben.
> Ningún servicio inserta compromisos, cambia etapas o crea links "a mano".

**Llaves:**
- Servidores de voz y WhatsApp → `SUPABASE_SECRET_KEY` (rol `service_role`).
- Web → `SUPABASE_PUBLISHABLE_KEY` + login (rol `authenticated`).
- Página pública `/pagar/[token]` → sin login (`anon`): solo `get_payment_link` y `simulate_payment`.

**Errores:** las funciones lanzan excepciones con prefijo legible
(`CONTACTO_NO_HABILITADO`, `CONTACTO_BLOQUEADO_POR_REGLA`, `GRUPO_DE_CONTROL`, `RESULTADO_INVALIDO`…).
Las validaciones de negocio **no** lanzan: devuelven `{ valid:false, errors:[…], instruction }`.

---

## 1. Ciclo de vida

```
run_detection()                         ← web: botón "Ejecutar detección"
   └─ interventions(status=scheduled)   ← la DECISIÓN preventiva, antes de contactar
        │
start_conversation(customer, canal)     ← voz / WhatsApp
   ├─ log_message(...)                  ← cada turno (agente y cliente)
   ├─ evaluate_turn(scorecard)          ← CONTROLADOR → etapa + instrucción [CONTROL]
   ├─ log_interruption(...)             ← voz: barge-in / asentimiento / ruido
   ├─ log_silence()                     ← voz: silencio prolongado
   ├─ validate_offer(código, params)    ← antes de decir montos/fechas
   ├─ register_commitment(..., true)    ← con "sí" explícito → recibo
   ├─ create_handoff('whatsapp', ...)   ← siguiente paso en otro canal
   ├─ request_escalation(...)           ← a humano
   ├─ record_model_usage(...)           ← costo/latencia
   └─ end_conversation(outcome)         ← cierre + riesgo después
        │
claim_handoff(id) → start_conversation(..., parent)   ← bot WhatsApp
get_payment_link(token) / simulate_payment(token)     ← página de pago
```

---

## 2. Funciones

### `start_conversation`
```
p_customer_id uuid, p_channel text ('voice'|'whatsapp'|'sms'|'email'|'simulator'),
p_direction text = 'outbound', p_external_id text = null, p_parent_conversation_id uuid = null,
p_intervention_id uuid = null, p_experiment_key text = null, p_force boolean = false
```
Abre la conversación y **congela** reglas, ofertas y restricciones (auditoría aunque alguien edite reglas a mitad de llamada).

Devuelve:
```jsonc
{
  "conversation_id": "…",
  "current_stage": "APERTURA",
  "models": {                       // configuración COMPLETA desde ai_model_profiles
    "voice_mode": "realtime",
    "voice_realtime": { "key": "voice.gemini-3.1-flash-live", "model_id": "gemini-3.1-flash-live-preview",
                        "params": { "temperature": 0.4, "voice_name": "Kore", … },
                        "vad_config": { "start_of_speech_sensitivity": "START_SENSITIVITY_LOW", "silence_duration_ms": 700, … },
                        "interruption_config": { "backchannel_phrases": ["ajá","mjm",…], "critical_stages": [...], … } },
    "supervisor": { "key": "supervisor.gemini-2.5-flash-lite", … },
    "composer":   { … }, "stt": { … }, "tts": { … }
  },
  "prompt_versions": { "voice.system": 1, "supervisor.scorecard": 1, … },
  "experiment": null | { "arm_key": "A", … },
  "warnings": ["FUERA_DE_HORARIO_DE_CONTACTO"],
  "context": { /* ver get_conversation_context */ }
}
```
Bloquea (excepción) si: `contact_enabled=false`, opt-out, grupo de control, sin consentimiento o regla de bloqueo. `p_force` salta regla y control group — **solo pruebas**.

### `get_conversation_context(p_customer_id)`
Todo lo que el agente puede saber. **No inventar nada fuera de esto.**
`customer`, `loan` (con `amount_due_text` y `next_due_date_text` ya formateados en español), `payment_behavior`, `risk` (score, banda, top 3 factores explicados), `signals`, `rules` (bloqueo, reglas activadas, tono), `offers` (permitidas, ordenadas), `max_offers_presented`, `constraints`, `playbook` (etapas con objetivo, instrucciones y criterios), `criteria_catalog`, `policies` (disclosure, interrupciones, ritmo, frases prohibidas), `history` (conversaciones previas, compromisos), `facts`.

### `log_message(p_conversation_id, p_role, p_content, p_meta = '{}')`
`p_role`: `agent` | `customer` | `system` | `tool`.
`p_meta` (todo opcional): `latency_ms`, `ttfb_ms`, `audio_ms`, `input_modality` (`audio`|`voice_note`|`image`|`text`), `media_url`, `model_profile_key`, `prompt_version_key`, `tokens_in`, `tokens_out`, `is_backchannel`.
Devuelve `{ message_id, seq, stage_key }`.

### `evaluate_turn(p_conversation_id, p_scorecard, p_message_id = null, p_meta = '{}')` ⭐
El **controlador**. El supervisor LLM evalúa el último intercambio con el esquema de `prompt_versions.output_schema` (key `supervisor.scorecard`); esta función decide de forma determinista:

1. **Transiciones globales** (`agent_policies.global_transitions`): fraude, pide humano, no contactar, tercero, frustración ×2, negativa ×2, rellamada, baja confianza, máximo de turnos.
2. **Reglas de salida de la etapa** (`playbook_stages.exit_rules`, editables en la web).
3. **Máximo de turnos en etapa.**

Devuelve:
```jsonc
{
  "decision": "stay|advance|jump|escalate|end",
  "from_stage": "DESCUBRIMIENTO", "to_stage": "PROPUESTA",
  "rule": { "id": "DES-2", "label": "Situación entendida" },
  "pace": "slow|normal|fast",
  "is_terminal": false, "suggested_outcome": null,
  "stage": { "key", "name", "objective", "instructions", "criteria", "allows_offers" },
  "allowed_offers": [ { "code": "PLAN_3_CUOTAS", "name": "…", "pitch": "…" } ],   // máx. 3
  "terms_to_restate": [],
  "escalation_id": null,
  "control_message": "[CONTROL] Etapa: Presentar opciones permitidas (PROPUESTA). Objetivo: … Ritmo: … Opciones permitidas: …"
}
```
- Valores del scorecard: usar `"yes"|"no"|"unknown"`. **`unknown` no es `no`**.
- `explicit_refusal` y `do_not_contact_request` los cuenta la BD (el LLM no lleva la cuenta).
- Si `decision = escalate` la BD **ya creó** la escalación.
- Si `do_not_contact_request = yes` la BD **ya registró** el opt-out.

### `log_interruption(p_conversation_id, p_kind, p_message_id, p_heard_text, p_played_ms, p_total_ms, p_customer_text, p_offer_code)`
`p_kind`: `real` | `backchannel` | `false_barge_in`.
Si es `real` durante `PROPUESTA|COMPROMISO|CONFIRMACION` (o con `p_offer_code`), marca esas ofertas como **condiciones no escuchadas** → `register_commitment` las rechazará hasta que se repitan (`validate_offer` de nuevo).
Devuelve `{ must_restate_terms, offers_to_restate, control_message }`.

### `log_silence(p_conversation_id)`
Devuelve `{ action:'reprompt', control_message }` o, al agotar reintentos, `{ action:'end', suggested_outcome:'ABANDONED', suggest_handoff:'whatsapp' }`.

### `validate_offer(p_conversation_id, p_offer_code, p_params = '{}', p_mark_presented = true)`
| Tipo | `p_params` |
|---|---|
| `FULL_PAYMENT`, `REMINDER` | `date?` |
| `DATE_EXTENSION` | `new_date` (YYYY-MM-DD) |
| `PARTIAL_PAYMENT` | `amount?`, `date?`, `remaining_date?` |
| `INSTALLMENT_PLAN` | `installments?`, `down_payment?`, `first_date?` |
| `FEE_WAIVER` | — |
| `CALLBACK` | `callback_date?`, `window?` |

**Las fechas las resuelve tu código** ("el viernes" → `2026-09-18`, zona `America/El_Salvador`), nunca el LLM.
Devuelve `{ valid, errors[], normalized_params, terms_text, requires_approval, instruction }`.
Ejemplo real: `"Pago inicial de $38.19 y el resto en 3 pagos de $50.92 cada 15 días, iniciando el martes 29 de septiembre. Sin intereses adicionales."`

### `register_commitment(p_conversation_id, p_offer_code, p_params, p_customer_confirmed)`
Rechaza con `errors` si: oferta inválida · `CONFIRMACION_EXPLICITA_REQUERIDA` · `CONDICIONES_NO_PRESENTADAS` · `CONDICIONES_INTERRUMPIDAS`.
Idempotente por oferta. Si requiere aprobación → `pending_approval` + escalación.
Devuelve `{ ok, receipt_code: "CMP-E3A899", commitment_id, status, summary, next_steps, instruction }`.
**Sin `receipt_code` el agente no puede decir "quedó registrado".**

### `create_payment_link(p_conversation_id, p_amount = null, p_commitment_id = null)`
→ `{ token, url, amount, amount_text, expires_at }`

### `create_handoff(p_conversation_id, p_to_channel, p_action, p_payload = '{}')`
`p_action`: `SEND_PAYMENT_LINK` (crea el link si no viene) · `SEND_COMMITMENT_SUMMARY` · `SEND_OFFER_DETAILS` · `FOLLOW_UP_MESSAGE` · `CALLBACK`.
→ `{ handoff_id, payload: { payment_url, commitment: {…} }, context_summary }`

### `claim_handoff(p_handoff_id)` / `complete_handoff(p_handoff_id, p_to_conversation_id, p_status)`
Toma atómica: dos workers no procesan el mismo handoff.

### `request_escalation(p_conversation_id, p_reason, p_priority = 'high', p_trigger)`

### `record_model_usage(p_conversation_id, p_model_key, p_usage)`
`p_usage`: `audio_in_seconds`, `audio_out_seconds` **o** `audio_in_tokens`, `audio_out_tokens`; `text_in_tokens`, `text_out_tokens`, `latency_ms`, `ttfb_ms`, `error`.
Calcula costo con `ai_model_profiles.pricing`. Con Gemini Live, pasar los tokens de `usageMetadata`.

### `end_conversation(p_conversation_id, p_outcome, p_summary = null, p_meta = '{}')`
`p_outcome` debe existir en `outcome_definitions`. Recalcula riesgo → `{ risk_before, risk_after, commitment_receipt, avg_latency_ms, p95_latency_ms }`.

### Otras
| Función | Uso |
|---|---|
| `find_customer_by_phone(p_phone)` | WhatsApp entrante |
| `set_demo_contact(p_customer_code, p_phone, p_email)` | Habilitar un personaje con un número real del equipo |
| `run_detection()` | Recalcula riesgo, aplica reglas, crea intervenciones |
| `match_rules(p_customer_id)` | "Probar reglas" para un cliente desde la web |
| `compute_risk(p_customer_id, p_persist)` | Riesgo con factores |
| `pick_experiment_arm(p_experiment_key, p_unit)` | Asignación A/B determinista |
| `reset_demo(p_reset_config = true)` | Deja todo como al inicio (~3 s; correr desde SQL editor si el RPC hace timeout) |
| `get_payment_link(token)`, `simulate_payment(token)` | Página pública de pago (anon) |

---

## 3. Vistas para la web

| Vista | Pantalla |
|---|---|
| `v_kpis` | Tarjetas principales (1 fila) |
| `v_prevention_impact` | Intervenidos vs grupo de control (⚠️ ilustrativo con datos sintéticos) |
| `v_live_conversations` | Llamadas/chats **en vivo** |
| `v_conversation_timeline` | Línea de tiempo: mensajes + evaluaciones + eventos |
| `v_customer_overview` | Cola de riesgo / ficha de cliente |
| `v_channel_performance` | Canal más efectivo |
| `v_rule_performance` | Qué regla convierte mejor |
| `v_offer_performance` | Qué oferta se acepta y se cumple |
| `v_stage_funnel` | Embudo por etapa + tasa de interrupción por etapa |
| `v_model_performance` | Laboratorio: latencia, costo y conversión por modelo |
| `v_daily_metrics`, `v_risk_distribution`, `v_sentiment_shift` | Gráficas |

**Realtime** (suscribirse con `postgres_changes`): `conversations`, `messages`, `turn_evaluations`, `conversation_events`, `interventions`, `commitments`, `handoffs`, `escalations`, `payment_links`, `detection_runs`.

---

## 4. Personajes de la demo

| Código | Nombre | Escenario | Qué demuestra |
|---|---|---|---|
| DEMO-001 | Carlos Martínez | **Voz dorada** · riesgo alto, vence en 2 días | 3 reglas apiladas, restricción más estricta gana (7 días) |
| DEMO-002 | María López | Cafetalera, temporada baja | Diferir a cosecha **con aprobación humana** |
| DEMO-003 | José Hernández | **WhatsApp** · buen pagador | Recordatorio amable + link |
| DEMO-004 | Ana Rivera | Perdió empleo | Playbook de dificultad económica |
| DEMO-005 | Luis Ramírez | Molesto, compromiso roto | Frustración → escalamiento |
| DEMO-006 | Sofía Castillo | Mora temprana (4 días) | Condonación de recargo |
| DEMO-007 | Pedro Flores | Corredor seco | Ruido de fondo / falsas interrupciones |
| DEMO-008 | Rosa Aguilar | Disputa abierta | **Bloqueada por regla** |
| DEMO-009 | Miguel Portillo | Grupo de control | Contrafactual: nunca se contacta |
| DEMO-010 | Carmen Mejía | Premium | Interruptor de regla R-PREMIUM |
| DEMO-011 | Jorge Alvarado | Pidió no ser contactado | **Bloqueado por opt-out** |
| DEMO-012 | Elena Guzmán | Evasiva | Negativa ×2, silencio |

Todos tienen teléfonos `+50300…` **no enrutables**. Para llamar o escribir de verdad:
```sql
select set_demo_contact('DEMO-001', '+503XXXXXXXX');
```
