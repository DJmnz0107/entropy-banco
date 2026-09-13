# CLAUDE.md — Banca Inteligente · Cobranza Preventiva

> **Entropía Hack 2026 · Reto Bancoagrícola.** Hackathon: este archivo cambia. Si una decisión cambia,
> actualízala aquí y en `docs/PLAN.md` en el mismo cambio.

## Qué construimos

Cobranza **preventiva**: detectar riesgo antes de la mora, decidir la intervención, llamar o escribir con
todo el contexto, **controlar la conversación** con reglas que configura el negocio, cerrar con un
call to action concreto, continuar por WhatsApp (link de pago) y medir todo en un dashboard en vivo.

**Diferenciador:** todos usan el mismo LLM. Aquí **el negocio controla la conversación**: reglas → ofertas
permitidas; playbooks → etapas con criterios; un controlador determinista decide etapa, ritmo y
escalamiento; la base de datos rechaza lo que el modelo invente.

Documentos:
- `docs/PLAN.md` — plan, reparto por persona, voz/interrupciones, guion de demo, herramientas.
- `docs/CONTRATO-API.md` — **contrato RPC** entre voz, WhatsApp y web. Leer antes de integrar.
- `docs/WEB-CENTRO-PREVENCION.md` — paso a paso de la web (Centro de Prevención, en vivo, impacto, configuración).
- `docs/AGENTE-VOZ-ELEVENLABS.md` — paso a paso del agente de voz con ElevenLabs.
- 🆕 = objetos de la migración 1200 (Motor de Prevención) **aún no creada**: `next_best_intervention`, `run_prevention`,
  `v_prevention_center`, `v_customer_financial_profile`, `intervention_steps`, `education_contents`, `v_impact`, `v_learning`.

## Decisiones vigentes

| Tema | Decisión |
|---|---|
| Fuente de verdad **y** lógica de negocio | **Supabase (Postgres)**: tablas + funciones RPC + vistas + Realtime |
| Canales | Voz (Josué) · WhatsApp vía Twilio Sandbox (compañero) · Web Next.js (2 personas) |
| LLM | **Gemini**, configurable por fila en `ai_model_profiles` (no hardcodear modelos) |
| Concepto | **Motor de Prevención / Next Best Intervention**: detectar → decidir la mejor intervención → contactar → adaptar → resolver → educar → seguir → medir → aprender. La voz es un brazo, no el producto |
| Segmentación | Calificación preventiva **A–E** (= bandas de riesgo) + categoría regulatoria SSF A1–E (por días de atraso). Llamadas priorizadas a C–D; E → humano |
| Voz | **ElevenLabs Agents + Custom LLM** (nuestro servidor responde `/v1/chat/completions` y ejecuta las tools contra Supabase). Plan B: LLM integrado + server tools. Gemini Live queda descartado |
| Supervisor / WhatsApp | Gemini Flash-Lite (endpoint compatible OpenAI) |
| Demo de voz | Navegador (WebRTC), **no** telefonía |
| Datos | 100% ficticios, seed determinista, fechas relativas a hoy (America/El_Salvador) |

Reemplaza decisiones anteriores (OpenAI, Vapi, backend TS `packages/core`): la lógica compartida está en SQL
porque 4 personas en 3 superficies no deben reimplementar reglas.

## Estructura

```
supabase/
  migrations/
    …0100_helpers.sql            sv_today(), aleatorio determinista, fmt_money, fmt_date_es, render_template
    …0200_customers_credit.sql   customers, loans, installments, payments, customer_signals, risk_assessments
    …0300_business_config.sql    offers, collection_rules, rule_offers, playbooks, playbook_stages,
                                 evaluation_criteria, rule_fact_definitions, outcome_definitions, agent_policies
    …0400_ai_lab.sql             ai_model_profiles, prompt_versions, experiments, experiment_arms, eval_scenarios, eval_runs
    …0500_operations.sql         detection_runs, interventions, conversations, messages, turn_evaluations,
                                 conversation_events, commitments, payment_links, handoffs, escalations, model_usage
    …0600_engine.sql             eval_condition, customer_facts, compute_risk, risk_band_for, match_rules,
                                 get_conversation_context, run_detection, pick_experiment_arm, resolve_models
    …0700_conversation_api.sql   start_conversation, log_message, evaluate_turn, log_interruption, log_silence,
                                 validate_offer, register_commitment, create_payment_link, create_handoff,
                                 claim_handoff, request_escalation, record_model_usage, end_conversation, …
    …0800_views.sql              v_kpis, v_live_conversations, v_conversation_timeline, v_customer_overview, …
    …0900_security_realtime.sql  RLS, grants, publicación realtime
    …1000_seed_config.sql        seed_config(): ofertas, reglas, playbooks, criterios, modelos, prompts, experimentos
    …1100_seed_data.sql          seed_personas(), seed_customers(), seed_history(), reset_demo()
  seed.sql                       select reset_demo();
  tests/                         runner PGlite (Postgres en WASM, sin Docker) + flow.sql (38 aserciones)
scripts/db-push.sh               prueba local → dry-run → push a Supabase
docs/
```

## Comandos

```bash
npm install
npm run db:test      # migraciones + seed + 38 aserciones del flujo de control en Postgres local (PGlite)
npm run db:metrics   # KPIs, distribución de riesgo, personajes, impacto
npm run db:push      # requiere SUPABASE_DB_URL en .env; corre db:test antes
```

SQL útil:
```sql
select reset_demo();                                   -- estado inicial completo (~3 s)
select reset_demo(false);                              -- conserva configuración editada en la web
select set_demo_contact('DEMO-001', '+503XXXXXXXX');   -- habilitar número real para llamar/escribir
select run_detection();
select match_rules('00000000-0000-4000-8000-000000000001');
```

**Antes de subir cualquier cambio de SQL: `npm run db:test` debe pasar.**

## Modelo de control

```
reglas (collection_rules, condiciones JSON) ──► ofertas permitidas + playbook + restricciones
                                                   (max_* gana el menor, min_* el mayor; block gana siempre)
cada turno: supervisor LLM → scorecard (evaluation_criteria) ──► evaluate_turn:
    1. transiciones globales (agent_policies.global_transitions)
    2. reglas de salida de la etapa (playbook_stages.exit_rules)
    3. máximo de turnos en etapa
  → decision + to_stage + pace + control_message [CONTROL]
acciones: validate_offer → register_commitment (recibo) → create_handoff / request_escalation
```

Un único lenguaje de condiciones para reglas **y** transiciones:
`{"all":[…]}`, `{"any":[…]}`, `{"not":{…}}`, `{"fact":"days_to_due","op":"between","value":[0,7]}`.
Operadores: `eq neq gt gte lt lte between in not_in contains not_contains is_true is_false is_null exists`.
Hecho ausente ⇒ `false` (salvo `is_null`).

Etapas (mismas llaves en todos los playbooks): `APERTURA → CONTEXTO → DESCUBRIMIENTO → PROPUESTA → OBJECIONES →
COMPROMISO → CONFIRMACION → SIGUIENTE_PASO` · terminales: `CIERRE, NEGATIVA_RESPETADA, ESCALADO, REAGENDADO, CIERRE_TERCERO`.

Riesgo: ponderado y explicable (`compute_risk`, pesos en `agent_policies.risk_weights`).
Bandas actuales: BAJO 0–24 · MODERADO 25–44 · PREVENTIVO 45–64 · ALTO 65–84 · CRÍTICO 85–100
(calibradas contra el seed; usar siempre `risk_band_for()`).

## Reglas inviolables

1. **El LLM propone, la BD autoriza y escribe.** Nunca insertar compromisos, cambiar etapas o crear links fuera de las RPC.
2. **Sin `receipt_code` no se dice "quedó registrado".**
3. **El LLM no calcula fechas ni montos.** Extrae texto literal; el código resuelve fechas en `America/El_Salvador`; `validate_offer` da montos y `terms_text`.
4. **Condiciones interrumpidas ⇒ repetirlas.** `log_interruption('real')` en etapas críticas bloquea `register_commitment` hasta un nuevo `validate_offer`.
5. **Scorecard tri-estado:** `"yes" | "no" | "unknown"`. `unknown` nunca es `no` (ver `jbool`).
6. **Negativa:** 1ª → una alternativa suave; 2ª → `NEGATIVA_RESPETADA`. "No me llamen" → opt-out automático.
7. **Antes de confirmar identidad no se menciona crédito, monto ni fecha.** Tercero ⇒ `CIERRE_TERCERO` sin datos.
8. **Seguridad de contacto:** solo `contact_enabled = true` recibe llamadas/mensajes en vivo. Grupo de control nunca.
9. **Modelos, precios y prompts viven en la BD.** Precio sin verificar ⇒ `pricing_verified_at = null`.
10. **`service_role` / secret key solo en servidores.** Nunca en el navegador ni con prefijo `NEXT_PUBLIC_`.
11. Nunca `current_date` / `now()::date` para "hoy": usar `sv_today()`.
12. PL/pgSQL: envolver `CASE` en paréntesis dentro de `IF … THEN`; usar `array_append` para `text[]`.

## Temperaturas

| Rol | Temp | Por qué |
|---|---|---|
| Supervisor / scorecard / resumen / juez | 0 | Clasificación estable y trazable |
| Composer WhatsApp | 0.3 | Natural sin inventar; a 0 repite frases |
| Voz realtime | 0.4 (a medir) | Prosodia natural; techo 0.5 |
| Cliente simulado (evals) | 0.9 | Es el cliente, debe ser impredecible. **Nunca** para el agente |

## Datos del seed

162 clientes (12 personajes `DEMO-001…012` con IDs fijos + 150 generados), ~2 400 cuotas, ~2 100 pagos,
~150 señales, ~60 conversaciones históricas con transcripciones, evaluaciones, interrupciones,
compromisos, links, handoffs y escalaciones. Ver la tabla de personajes en `docs/CONTRATO-API.md`.

⚠️ Teléfonos `+50300…` no enrutables, emails `@correo-demo.test`.
⚠️ `v_prevention_impact` y el historial son **sintéticos**: ilustran el mecanismo, no son evidencia. Decirlo en el pitch.

## Fuera de alcance

ML entrenado, fine-tuning, banca real, pagos reales, PSTN en demo, voz entrante, multi-idioma, RAG, colas, tests de UI.
Si una tarea empuja hacia esto, decirlo y proponer la versión mínima.
