# CLAUDE.md — Banca Inteligente · Cobranza Preventiva

> **Entropía Hack 2026 · Reto Bancoagrícola**
> Sistema de cobranza **preventiva** con agente de IA multicanal (WhatsApp + Voz),
> motor de riesgo explicable, policy engine determinista y dashboard en tiempo real.

Este archivo es la fuente de verdad operativa del repositorio. Si algo aquí
contradice el `README.md` de la propuesta original, **manda este archivo**.

---

## 1. Contexto del reto

> "¿Cómo evitar que un usuario caiga en mora **antes** de que suceda? La cobranza
> tradicional reacciona tarde. Transforma la cobranza en una experiencia empática
> con enfoque preventivo que vela por el récord crediticio de los usuarios."

**Lo que NO estamos construyendo:** un chatbot de cobranza.

**Lo que SÍ estamos construyendo:** un sistema que detecta señales tempranas de
riesgo, decide y registra una intervención *antes* de contactar, conversa de forma
empática dentro de límites de política, negocia un compromiso concreto, y convierte
cada interacción en dato accionable.

El bucle completo:

```
DETECTA → PRIORIZA → DECIDE → CONTACTA → COMPRENDE → NEGOCIA → CIERRA → REGISTRA → MIDE
```

---

## 2. Decisiones ya tomadas — NO re-litigar

Estas decisiones están cerradas. No proponer alternativas salvo que el usuario
las reabra explícitamente.

| Decisión | Elección | Razón |
|---|---|---|
| Canal | **Doble demo: WhatsApp (principal) + Voz (Vapi)** | Cobertura del brief + impacto en vivo |
| Proveedor LLM | **OpenAI** | Decisión del equipo |
| Base de datos | **Supabase** (Postgres + Realtime) | Fuente única de verdad compartida |
| Repositorio | **Monorepo** (pnpm + Turborepo) | Compartir `packages/core` entre canales |
| Dashboard | **Next.js 15 + Tailwind + shadcn/ui + Recharts** | Velocidad |
| Agent runtime | **Hono + Node 20 (TS)** | Proceso caliente, sin cold start para Vapi |
| WhatsApp | **Twilio WhatsApp Sandbox** | Activable en minutos, sin aprobación de Meta |
| Datos | **100% ficticios** | Requisito del hackathon |

### La decisión arquitectónica central

> El cerebro del agente (riesgo, políticas, decisión, persistencia) vive **fuera del
> canal** y se expone como una **Tool API HTTP**. Vapi la consume como custom tools.
> El loop de WhatsApp la consume como funciones locales.
> **Una sola lógica de negocio, múltiples canales.**

**Nunca** duplicar reglas de negocio dentro de un prompt de canal. Si una regla
existe en `packages/core/src/policy`, el prompt la *referencia*; no la reimplementa.

---

## 3. Arquitectura

```
                    ┌──────────────────────────────────────┐
                    │  DETECTOR (cron)                     │
                    │  risk engine → contact policy → NBA  │
                    └──────────────┬───────────────────────┘
                                   │ crea intervention (status=scheduled)
                                   ▼
        ┌──────────────────── CHANNEL ROUTER ────────────────────┐
        ▼                    ▼                ▼                  ▼
   WhatsApp             Voz (Vapi)          SMS              Email
   Twilio           Deepgram + 11Labs      Twilio            Resend
        │                    │                │                  │
        └────────────────────┴────────┬───────┴──────────────────┘
                                      ▼
                    ══════ CONVERSATION CORE (compartido) ══════
                                      │
         ┌────────────────┬───────────┴────────┬────────────────┐
         ▼                ▼                    ▼                ▼
   1. ANALYZER     2. POLICY ENGINE      3. COMPOSER    4. GUARDRAIL
   LLM temp 0      DETERMINISTA          LLM temp 0.3   DETERMINISTA
   structured      allowed_actions[]     solo texto     pre-envío
   output          constraints{}         sin tools      grounding
                   mustEscalate          max_tokens     blocklist
         └────────────────┴───────────┬────────┴────────────────┘
                                      ▼
                            5. EXECUTOR / TOOL API
                       (ÚNICO con permiso de escritura)
                                      │
                         ┌────────────▼────────────┐
                         │  SUPABASE — Truth       │
                         └────────────┬────────────┘
                                      │ Realtime
                                      ▼
                              DASHBOARD (Next.js)
```

### Por qué voz y texto se tratan distinto

Vapi corre su propio loop LLM en tiempo real. No podemos meter nuestras 5 etapas
dentro de una llamada sin destruir el P95.

- **En WhatsApp/SMS/Email:** corremos las 5 etapas nosotros.
- **En voz:** Vapi hace las etapas 1 y 3 (analyze + compose) con el system prompt
  que nosotros generamos; las etapas 2, 4 y 5 (policy, guardrail, executor) las
  invoca vía **custom tools HTTP** contra nuestra Tool API.

Resultado: mismas reglas de negocio, mismo Policy Engine, mismos writes.

---

## 4. Estructura del monorepo

```
entropy-banco/
├── CLAUDE.md                      ← este archivo
├── package.json                   # pnpm workspaces
├── turbo.json
├── pnpm-workspace.yaml
│
├── apps/
│   ├── agent/                     # Hono + Node 20 — cerebro + webhooks
│   │   └── src/
│   │       ├── index.ts
│   │       ├── routes/
│   │       │   ├── webhooks.whatsapp.ts    # Twilio inbound
│   │       │   ├── webhooks.vapi.ts        # eventos de llamada
│   │       │   ├── tools.ts                # TOOL API (Vapi + interno)
│   │       │   ├── simulator.ts            # canal simulador para fallback
│   │       │   └── admin.ts                # trigger manual de detección
│   │       ├── pipeline/
│   │       │   ├── run.ts                  # orquestador de las 5 etapas
│   │       │   ├── analyze.ts
│   │       │   ├── compose.ts
│   │       │   └── execute.ts
│   │       ├── channels/
│   │       │   ├── types.ts                # interfaz Channel (contrato)
│   │       │   ├── whatsapp.twilio.ts
│   │       │   ├── voice.vapi.ts
│   │       │   ├── sms.twilio.ts
│   │       │   ├── email.resend.ts
│   │       │   └── simulator.ts
│   │       ├── llm/
│   │       │   ├── client.ts               # wrapper OpenAI
│   │       │   ├── schemas.ts              # JSON Schemas de structured output
│   │       │   └── prompts/
│   │       │       ├── system.policy.ts    # bloque de política (compartido)
│   │       │       ├── analyzer.ts
│   │       │       ├── composer.whatsapp.ts
│   │       │       └── composer.voice.ts
│   │       ├── scheduler/
│   │       │   ├── detect.ts               # recalcula riesgo, crea interventions
│   │       │   └── dispatch.ts             # envía el primer mensaje
│   │       └── observability/
│   │           ├── trace.ts
│   │           └── latency.ts
│   │
│   └── dashboard/                 # Next.js 15 (App Router)
│       ├── app/
│       │   ├── page.tsx                    # KPIs principales
│       │   ├── riesgo/                     # cola de clientes en riesgo
│       │   ├── conversaciones/[id]/        # timeline reconstruible
│       │   ├── clientes/[id]/
│       │   ├── escalaciones/
│       │   └── politicas/                  # policy YAML activo (gobernanza)
│       ├── components/
│       ├── charts/
│       └── lib/supabase/
│
├── packages/
│   ├── core/                      # ⚠️ TS PURO. CERO I/O. 100% testeable.
│   │   └── src/
│   │       ├── risk/              # scoring 0-100 + factors explicables
│   │       ├── policy/            # validación, allowed_actions, escalamiento
│   │       ├── nba/               # tabla de decisión Next Best Action
│   │       ├── guardrails/        # filtro pre-envío
│   │       ├── dates/             # resolución determinista ES-SV / UTC-6
│   │       └── types/             # tipos de dominio compartidos
│   │
│   ├── db/                        # cliente Supabase, tipos generados, repos
│   └── config/                    # tsconfig / eslint / tailwind compartidos
│
├── supabase/
│   ├── migrations/
│   └── seed/
│       ├── customers.ts           # 60-80 clientes ficticios, seed determinista
│       └── control-cohort.ts      # 30% marcados control=true (nunca contactados)
│
├── policies/
│   └── bancoagricola.v1.yaml      # políticas como DATOS, versionadas
│
└── docs/
    ├── DEMO-RUNBOOK.md
    └── SCENARIOS.md
```

### Regla de dependencias — estricta

```
packages/core   → no depende de NADA (ni Supabase, ni OpenAI, ni fetch)
packages/db     → depende de core
apps/agent      → depende de core + db
apps/dashboard  → depende de core + db
```

Si algo en `packages/core` necesita hacer una llamada de red, **está en el lugar
equivocado**. Ese es el paquete que garantiza que las reglas de negocio sean
testeables en milisegundos y compartidas entre canales.

---

## 5. Comandos

```bash
pnpm install

pnpm dev                  # agent + dashboard en paralelo
pnpm dev:agent            # solo el agente  (:8787)
pnpm dev:dashboard        # solo dashboard  (:3000)

pnpm test                 # vitest sobre packages/core
pnpm test:watch
pnpm typecheck
pnpm lint

pnpm db:migrate           # aplica migrations a Supabase
pnpm db:types             # regenera tipos TS desde el schema
pnpm db:seed              # datos ficticios (seed determinista)
pnpm db:reset             # migrate + seed desde cero

pnpm demo:reset           # ⭐ deja la DB en el estado exacto de la demo
pnpm demo:scenario <A-E>  # ejecuta un escenario de conversación
pnpm tunnel               # ngrok con dominio reservado
```

`pnpm demo:reset` debe poder correrse **entre ensayos del pitch** y dejar todo
idéntico. Mantenerlo funcionando es prioridad alta.

---

## 6. Modelo de dominio y glosario

| Término | Significado |
|---|---|
| **Intervention** | La *decisión* de contactar. Existe **antes** del contacto. Es lo que hace que esto sea preventivo y no reactivo. |
| **Conversation** | Un intercambio en un canal. Generaliza "llamada" y "chat". |
| **Risk Score** | 0–100, determinista y explicable. Sin ML. |
| **Risk Band** | `BAJO` 0-24 · `MODERADO` 25-49 · `PREVENTIVO` 50-74 · `ALTO` 75-89 · `CRITICO` 90-100 |
| **NBA** | Next Best Action. Salida de una tabla de decisión, no de un LLM. |
| **Decision** | Objeto que produce el Policy Engine. Contiene `allowedActions[]`. |
| **Receipt** | Comprobante de escritura exitosa. Sin él, el agente **no puede confirmar nada**. |
| **Outcome** | Cierre inequívoco de una conversación. Nunca "lo voy a pensar". |
| **Cohorte de control** | Clientes en riesgo deliberadamente NO contactados, para medir mora evitada contra un contrafactual. |

### Enums canónicos

```ts
type Intent =
  | 'WILL_PAY' | 'NEEDS_ALTERNATIVE_DATE' | 'FINANCIAL_DIFFICULTY'
  | 'REFUSES' | 'ANGRY' | 'EVASIVE' | 'REQUESTS_HUMAN'
  | 'DISPUTE' | 'POSSIBLE_FRAUD' | 'CONFIRMS' | 'UNKNOWN';

type Sentiment = 'POSITIVE' | 'NEUTRAL' | 'CONCERNED' | 'FRUSTRATED' | 'ANGRY';

type Outcome =
  | 'PAYMENT_COMMITMENT' | 'ALTERNATIVE_DATE' | 'PARTIAL_PAYMENT'
  | 'EXPLICIT_REFUSAL' | 'HUMAN_ESCALATION' | 'FOLLOW_UP_REQUIRED'
  | 'NO_ANSWER' | 'ABANDONED';

type Channel = 'whatsapp' | 'voice' | 'sms' | 'email' | 'simulator';

type NBA =
  | 'FRIENDLY_REMINDER' | 'PREVENTIVE_FOLLOWUP' | 'NEGOTIATE'
  | 'OFFER_ALTERNATIVE_DATE' | 'CONFIRM_COMMITMENT' | 'REDUCE_PRESSURE'
  | 'ESCALATE' | 'CLOSE_REFUSAL' | 'SCHEDULE_FOLLOWUP' | 'NO_CONTACT';
```

Estos strings aparecen en la DB, en los prompts y en el dashboard. **No renombrar
sin actualizar los tres lugares.**

---

## 7. Esquema de base de datos

14 tablas. Generalizadas desde el README original (`calls` → `conversations`) para
soportar los cuatro canales con un solo modelo.

```sql
-- ═══ DATOS DEL CLIENTE (ficticios) ═══
customers(
  id uuid pk, full_name text, document_id text, phone_e164 text,
  email text, segment text, preferred_channel channel,
  preferred_time_window text, language text default 'es-SV',
  consent_whatsapp bool, consent_voice bool, opted_out_at timestamptz,
  is_control bool default false,          -- cohorte de control
  created_at timestamptz
)

loans(
  id uuid pk, customer_id uuid fk, product_type text,
  principal numeric, balance numeric, installment_amount numeric,
  due_date date, cycle_day int, status text, opened_at date
)

payments(
  id uuid pk, loan_id uuid fk, amount numeric, paid_at date,
  due_date_ref date, days_late int, status text
)

-- ═══ INTELIGENCIA PREVENTIVA ═══
risk_scores(
  id uuid pk, customer_id uuid fk, loan_id uuid fk,
  score int, risk_band text, probability_default numeric,
  factors jsonb,                          -- [{factor, weight, contribution, detail}]
  model_version text, computed_at timestamptz
)

interventions(                            -- ⭐ LA DECISIÓN PREVENTIVA
  id uuid pk, customer_id uuid fk, loan_id uuid fk, risk_score_id uuid fk,
  nba text, channel channel, reason text, rule_ids jsonb,
  scheduled_for timestamptz, status text, -- scheduled|dispatched|completed|skipped
  policy_version text, created_at timestamptz
)

-- ═══ CONVERSACIÓN ═══
conversations(
  id uuid pk, intervention_id uuid fk, customer_id uuid fk, loan_id uuid fk,
  channel channel, external_id text,      -- vapi call id / twilio sid
  direction text, status text,
  started_at timestamptz, ended_at timestamptz, duration_ms int,
  outcome text, outcome_detail jsonb,
  final_intent text, initial_sentiment text, final_sentiment text,
  escalated bool, turn_count int,
  risk_before int, risk_after int
)

messages(
  id uuid pk, conversation_id uuid fk, turn int,
  role text,                              -- customer|agent|system
  content text, sent_at timestamptz,
  latency_ms int, model text, prompt_tokens int, completion_tokens int,
  blocked_by_guardrail bool, raw jsonb
)

analysis_results(                         -- intent + sentiment en una fila
  id uuid pk, conversation_id uuid fk, message_id uuid fk,
  intent text, intent_confidence numeric,
  sentiment text, sentiment_score numeric,
  entities jsonb,                         -- {date_text, resolved_date, amount}
  model text, latency_ms int, created_at timestamptz
)

agent_decisions(                          -- auditoría: POR QUÉ hizo lo que hizo
  id uuid pk, conversation_id uuid fk, message_id uuid fk,
  risk_band text, intent text, sentiment text,
  nba text, allowed_actions jsonb, constraints jsonb,
  rule_ids jsonb, must_escalate bool,
  policy_version text, decided_at timestamptz
)

payment_commitments(
  id uuid pk, conversation_id uuid fk, customer_id uuid fk, loan_id uuid fk,
  committed_date date, committed_amount numeric,
  type text,                              -- full|partial|alternative_date
  status text,                            -- pending|kept|broken|cancelled
  confirmed_by_customer bool, validated_by_policy bool,
  created_at timestamptz
)

escalations(
  id uuid pk, conversation_id uuid fk, customer_id uuid fk,
  reason text, trigger text, priority text, status text,
  assigned_to text, notes text, created_at timestamptz, resolved_at timestamptz
)

events(                                   -- observabilidad + latencia
  id uuid pk, conversation_id uuid fk, type text,
  payload jsonb, latency_ms int, error text, occurred_at timestamptz
)

guardrail_violations(
  id uuid pk, conversation_id uuid fk, message_id uuid fk,
  rule text, severity text, original_text text, action_taken text,
  created_at timestamptz
)

policies(
  id uuid pk, version text, name text, config jsonb,
  active bool, created_at timestamptz
)
```

### Índices mínimos

```sql
create index on risk_scores (customer_id, computed_at desc);
create index on interventions (status, scheduled_for);
create index on conversations (customer_id, started_at desc);
create index on messages (conversation_id, turn);
create index on events (conversation_id, occurred_at);
create index on loans (due_date) where status = 'active';
```

### RLS

- El **agente** usa `service_role` (solo server-side, nunca en el navegador).
- El **dashboard** usa `anon` con RLS que permite `select` a usuarios autenticados.
- Nunca exponer `SUPABASE_SERVICE_ROLE_KEY` al cliente. Nunca prefijarla `NEXT_PUBLIC_`.

---

## 8. Risk Engine

Determinista, ponderado, explicable. **Sin ML.** La explicabilidad vale más que la
precisión en esta demo: un jurado de banco pregunta "¿por qué 84?".

```ts
// packages/core/src/risk/score.ts
type RiskFactor = {
  id: string; label: string; weight: number;
  value: number; contribution: number; detail: string;
};
```

| Factor | Peso | Señal |
|---|---:|---|
| `due_proximity` | 25 | Días hasta el vencimiento (más cerca = más alto) |
| `late_payment_ratio` | 25 | Pagos tardíos / pagos totales |
| `max_days_late` | 15 | Peor atraso histórico |
| `days_since_last_payment` | 10 | Contra el ciclo esperado |
| `balance_to_installment` | 10 | Saldo / cuota |
| `recent_trend` | 10 | Dirección de los últimos 3 pagos |
| `broken_commitments` | 5 | Compromisos previos incumplidos |

`probability_default` = transformación logística del score, **calibrada contra el
dataset sintético**. Es demostrativa, no un modelo de crédito. Documentarlo así
siempre.

Salida obligatoria: `{ score, band, probability_default, factors[] }`.
El dashboard **debe** mostrar los top 3 `factors` por cliente.

Umbrales configurables en `policies/*.yaml`, no hardcodeados.

---

## 9. Policy Engine — reglas de negocio

### Principio rector

> **La IA decide CÓMO conversar. Las reglas determinan QUÉ puede ofrecer.**

`policies/bancoagricola.v1.yaml` — políticas como datos, versionadas, cargables en
caliente, **visibles en el dashboard** (`/politicas`). Esto responde al requisito de
"scripts y políticas provistos por la empresa como instrucciones y guardrails".

```yaml
version: "1"
name: Bancoagrícola · Cobranza Preventiva

negotiation:
  max_extension_days: 30
  min_partial_payment_pct: 0.25
  allowed_outcomes:
    - PAYMENT_COMMITMENT
    - ALTERNATIVE_DATE
    - PARTIAL_PAYMENT
    - HUMAN_ESCALATION
    - EXPLICIT_REFUSAL
    - FOLLOW_UP_REQUIRED
  forbidden_weekdays: [sunday]

contact:
  quiet_hours: { start: "20:00", end: "08:00", tz: "America/El_Salvador" }
  max_contacts_per_week: 2
  cooldown_hours: 48
  max_turns_per_conversation: 12
  stop_on_explicit_refusal: true     # una negativa cierra; no se insiste

escalation_triggers:
  - customer_requests_human
  - intent_in: [DISPUTE, POSSIBLE_FRAUD]
  - sentiment_ANGRY_consecutive: 2
  - low_confidence_consecutive: 2     # confidence < 0.6
  - requested_extension_exceeds_max

disclosure:
  required_opening: "Le escribe el asistente digital de Bancoagrícola."
  must_identify_as_automated: true

risk_bands:
  BAJO: [0, 24]
  MODERADO: [25, 49]
  PREVENTIVO: [50, 74]
  ALTO: [75, 89]
  CRITICO: [90, 100]
```

### Tabla Next Best Action

```
risk_band   × intent                  → NBA
────────────────────────────────────────────────────────────────
BAJO        × (sin conversación)      → NO_CONTACT
MODERADO    × (sin conversación)      → FRIENDLY_REMINDER
PREVENTIVO  × (sin conversación)      → PREVENTIVE_FOLLOWUP
ALTO        × (sin conversación)      → NEGOTIATE
CRITICO     × (sin conversación)      → NEGOTIATE (prioridad alta)
*           × WILL_PAY                → CONFIRM_COMMITMENT
*           × NEEDS_ALTERNATIVE_DATE  → OFFER_ALTERNATIVE_DATE
*           × FINANCIAL_DIFFICULTY    → OFFER_ALTERNATIVE_DATE
*           × EVASIVE                 → NEGOTIATE (pedir fecha concreta, 1 vez)
*           × ANGRY                   → REDUCE_PRESSURE
*           × FRUSTRATED ×2 turnos    → ESCALATE
*           × REQUESTS_HUMAN          → ESCALATE
*           × DISPUTE                 → ESCALATE
*           × POSSIBLE_FRAUD          → ESCALATE (inmediato)
*           × REFUSES                 → CLOSE_REFUSAL
```

Implementar como tabla de datos, no como `if/else` anidados. Tiene que ser legible
en una diapositiva.

---

## 10. Pipeline del agente — el contrato

```ts
analyze(ctx, history, lastMsg)  →  Analysis   // LLM temp 0, JSON Schema
decide(analysis, ctx, risk)     →  Decision   // TS puro, 0 red, testeable
compose(decision, ctx)          →  string     // LLM temp 0.3, SIN tools
guard(text, decision, ctx)      →  Verdict    // TS puro, pre-envío
execute(decision, payload)      →  Receipt    // ÚNICO write, re-valida todo
```

```ts
type Decision = {
  nba: NBA;
  allowedActions: Action[];          // lista blanca; vacía = solo conversar
  constraints: { maxDate?: string; minAmount?: number; maxExtensionDays: number };
  tone: 'warm' | 'neutral' | 'deescalate';
  mustEscalate: boolean;
  ruleIds: string[];                 // → agent_decisions, para auditoría
};
```

### Reglas inviolables del pipeline

1. **El LLM nunca escribe.** Propone; el Policy Engine autoriza; código determinista
   persiste. El Composer no recibe herramientas de escritura. Nunca.
2. **El LLM nunca calcula fechas.** Extrae el texto ("el viernes"); lo resuelve
   `packages/core/src/dates` con `America/El_Salvador` (UTC-6). Esta es la fuente #1
   de bugs sutiles en este dominio.
3. **El LLM nunca inventa cifras.** Todo monto y saldo viene del contexto inyectado.
   El Guardrail lo verifica (ver §12).
4. **Sin `Receipt`, no hay confirmación.** El agente no puede decir "queda
   registrado" salvo que un `Receipt` de escritura exitosa esté en su contexto.
   Esto implementa el principio de consistencia del README §45.
5. **`execute()` re-valida todo server-side.** Nunca confiar en que el argumento
   que llega desde el LLM (o desde una tool call de Vapi) ya pasó por la política.
6. **Toda decisión se persiste con sus `ruleIds`.** Si el dashboard no puede explicar
   por qué el agente hizo algo, la funcionalidad no está terminada.

---

## 11. Configuración LLM

**No usar una sola temperatura para todo el sistema.** Cada etapa tiene la suya.

| Etapa | Modelo | Temp | max_tokens | Modo |
|---|---|---:|---:|---|
| Analyzer | `gpt-4.1-mini` | **0** | 300 | Structured Outputs, schema estricto |
| Composer WhatsApp | `gpt-4.1` | **0.3** | 120 | Texto plano |
| Composer Voz (en Vapi) | `gpt-4.1-mini` | **0.3** | 60 | Texto plano |
| Resumen de cierre | `gpt-4.1-mini` | **0** | 200 | Structured Outputs |
| Policy / decisión | — | — | — | **Cero LLM** |

Resto de parámetros: `top_p: 1`, `frequency_penalty: 0`, `presence_penalty: 0`,
`seed` fijo donde el API lo soporte (reproducibilidad de la demo).

**Justificación de la temperatura — importante para el pitch:**

- **0 en el Analyzer:** clasificar `FINANCIAL_DIFFICULTY` vs `REFUSES` de forma
  inestable rompe la trazabilidad y las métricas. Determinismo obligatorio.
- **0.3 en el Composer:** a temperatura 0 el modelo repite frases literales entre
  clientes y la conversación se siente robótica — exactamente lo contrario del
  requisito de empatía y personalización. 0.3 da variación natural sin deriva.
- **Techo duro de 0.4.** En contexto financiero, consistencia > creatividad.

Los IDs de modelo viven en config, no hardcodeados. **Verificarlos contra la API
vigente antes de fijarlos** — no asumir disponibilidad.

### Construcción del prompt

```
SYSTEM POLICY (desde policies/*.yaml — idéntico en todos los canales)
  + CUSTOMER CONTEXT (nombre, producto, saldo, fecha, últimos pagos)
  + RISK CONTEXT (score, band, top 3 factors)
  + CONVERSATION HISTORY
  + CURRENT INTENT + SENTIMENT
  + NEXT BEST ACTION
  + ALLOWED ACTIONS + CONSTRAINTS
  ↓
RESPUESTA
```

El bloque SYSTEM POLICY se genera desde el YAML, no se escribe a mano. Así cambiar
`max_extension_days` cambia el comportamiento del agente en los cuatro canales sin
tocar código.

### Estilo del agente

Cálido, profesional, breve, natural, respetuoso, empático. Español salvadoreño,
trato de **usted**. WhatsApp: máximo 2 frases por mensaje. Voz: máximo 1–2 frases
(el TTS largo mata el P95 y suena a robot).

---

## 12. Guardrails

### El agente NUNCA debe

amenazar · acosar · manipular emocionalmente · inventar consecuencias legales ·
inventar saldos, fechas o políticas · ofrecer condiciones no autorizadas ·
insistir tras una negativa explícita · ocultar que es un asistente automatizado ·
confirmar una operación que no se persistió.

### Filtro pre-envío (determinista, `packages/core/src/guardrails`)

1. **Blocklist** de amenazas y consecuencias legales inventadas.
2. **Grounding numérico** — toda cifra y fecha del mensaje debe existir en el
   contexto autorizado. Si el modelo escribe "$1,350" y el saldo es $1,200 → bloqueo.
3. **Regla del Receipt** — "queda registrado" / "confirmado" sin `Receipt` → bloqueo.
4. **Política de oferta** — ninguna fecha fuera de `maxExtensionDays`, ningún monto
   bajo `min_partial_payment_pct`.
5. **Longitud** máxima por canal.
6. **Disclosure** — el primer mensaje debe identificar al asistente como automatizado.

Al fallar: 1 reintento con el motivo inyectado → si vuelve a fallar, plantilla
segura + fila en `guardrail_violations`.

Las violaciones se muestran en el dashboard. **Es una funcionalidad, no un error log:**
demuestra gobernanza frente a un jurado de banco.

### Escalamiento obligatorio

El cliente pide un humano · disputa · posible fraude · frustración sostenida ·
extensión fuera de política · baja confianza sostenida · el agente no puede resolver.

Al escalar: detener la automatización, escribir en `escalations`, informar al cliente
con claridad, cerrar con `outcome = HUMAN_ESCALATION`.

---

## 13. Canales

Todos implementan la misma interfaz. Agregar un canal = agregar un archivo.

```ts
// apps/agent/src/channels/types.ts
interface Channel {
  id: ChannelId;
  send(to: Recipient, text: string, ctx: SendContext): Promise<SendReceipt>;
  parseInbound(raw: unknown): InboundMessage;
  verifySignature(req: Request): boolean;
  capabilities: { realtime: boolean; maxLength: number; supportsRichText: boolean };
}
```

| Canal | Estado en el MVP | Notas |
|---|---|---|
| `whatsapp` | **Real** — Twilio Sandbox | Join codes hechos **el día antes**, no en el escenario |
| `voice` | **Real** — Vapi web call | **Usar web widget, NO PSTN.** El wifi del venue es un riesgo real. |
| `email` | **Real** — Resend | ~20 min de integración, demuestra multicanal barato |
| `sms` | **Stub** — escribe en DB | Adaptador completo, envío simulado |
| `simulator` | **Real** | UI web con el mismo contrato de webhook. **Plan B si la red falla.** |

El simulador no es un juguete: es el seguro de la demo. Debe recorrer exactamente
el mismo pipeline que WhatsApp.

---

## 14. Métricas

### KPI estrella — Mora Evitada

Definición operativa (sin esto, el número no es defendible):

> Clientes con `risk_band >= PREVENTIVO` que recibieron intervención **antes** del
> `due_date` y registraron un compromiso cumplido o un pago en/antes de la fecha
> comprometida.

**Contra la cohorte de control.** El seeder marca ~30% de los clientes en riesgo
como `is_control = true`; nunca se les contacta. El dashboard muestra:

```
Mora en intervenidos: 18%   vs   Cohorte de control: 47%
```

Sin contrafactual, "mora evitada" es un número sin significado y un jurado de banco
lo va a notar. Con él, es la diapositiva más fuerte del pitch.

### Métricas complementarias

```
Preventive Intervention Rate = intervenidos / detectados en riesgo
Commitment Rate              = compromisos / conversaciones completadas
Agreement Rate               = acuerdos / conversaciones
Escalation Rate              = escalaciones / conversaciones
Response Rate                = conversaciones con respuesta / mensajes enviados
Risk Reduction               = risk_before − risk_after
Commitment Kept Rate         = compromisos cumplidos / compromisos
Sentiment Shift              = initial_sentiment → final_sentiment
Canal más efectivo           = commitment rate por canal
Guardrail Violation Rate     = violaciones / mensajes generados
Latencia                     = P50 / P95 / P99 por canal y por etapa
```

### Latencia

Objetivo: **P95 < 2s en voz.** Se mide, no se asume. Eventos en `events`:

```
user_audio_start · user_audio_end · endpoint_detected · stt_final
llm_request_start · llm_first_token · tts_request_start · tts_first_audio
assistant_audio_end
```

En WhatsApp el objetivo es más laxo (P95 < 4s) — no hay presión conversacional
de tiempo real. No optimizar WhatsApp a costa de complejidad.

---

## 15. Datos ficticios

**100% ficticios. Cero datos reales de Bancoagrícola.** Declararlo en el pitch.

Seed determinista (`seed` fijo) con 60–80 clientes distribuidos en perfiles:

| Perfil | % | Características |
|---|---:|---|
| Excelente historial | 25% | Sin atrasos, score 5–20 |
| Buen pagador ocasional | 25% | 1–2 atrasos menores, score 25–45 |
| Riesgo preventivo | 20% | Patrón de atrasos, score 50–74 |
| Riesgo alto | 20% | Atrasos frecuentes, score 75–89 |
| Crítico | 10% | Compromisos rotos, score 90+ |

De los que están en `PREVENTIVO+`, marcar 30% como `is_control = true`.

Fechas relativas a `NOW()` para que la demo siempre tenga vencimientos "en 3 días".
**No hardcodear fechas absolutas** — el seed se rompe al día siguiente.

Los personajes de la demo (Carlos Martínez score 84, María López score 78) tienen
IDs fijos para que el runbook sea reproducible.

---

## 16. Testing

Prioridad estricta, en este orden:

1. **Unit sobre `packages/core`** — es lo único obligatorio. Risk engine, policy
   engine, NBA, guardrails, resolución de fechas. Rápido, sin red, alta cobertura.
2. **Conversation tests** — los 5 escenarios (§17) contra transcripts fijos,
   afirmando `intent`, `outcome` y `ruleIds`.
3. **Integration** — persistencia en Supabase, firma de webhooks. Mínimo.

**No escribir tests de UI del dashboard.** No es buen uso del tiempo en 40 horas.

Casos de borde que **sí** hay que testear:
- "el viernes" en martes vs en sábado (resolución de fecha)
- fecha propuesta a 31+ días → debe rechazarse y escalar
- fecha en domingo → debe rechazarse (política)
- cambio de mes/año ("el 3" dicho el 28 de diciembre)
- monto parcial bajo el 25% → rechazo
- negativa explícita → cierre sin reintento
- guardrail: mensaje con un monto que no existe en el contexto

---

## 17. Escenarios de demo

| # | Perfil | Entrada del cliente | Resultado esperado |
|---|---|---|---|
| A | Cooperativo | "Sí, claro. Puedo pagar el viernes." | `PAYMENT_COMMITMENT` |
| B | Evasivo | "Después veo eso." | Pide fecha concreta **una vez** → `FOLLOW_UP_REQUIRED` o `PAYMENT_COMMITMENT` |
| C | Dificultad financiera | "Este mes ando complicado." | `FINANCIAL_DIFFICULTY` → `ALTERNATIVE_DATE` dentro de política |
| D | Molesto | "Ya me tienen cansado con estas llamadas." | Baja fricción; si persiste → `HUMAN_ESCALATION` |
| E | Pide humano | "Quiero hablar con una persona." | `HUMAN_ESCALATION` inmediato |

Cada uno debe correrse con `pnpm demo:scenario A`.

**Escenario C es el escenario dorado del pitch.** Es el que mejor demuestra
prevención + empatía + negociación + límites de política + registro.

---

## 18. Variables de entorno

Nunca commitear `.env`. Mantener `.env.example` actualizado.

```env
# Supabase
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=        # SOLO server-side. Nunca NEXT_PUBLIC_.

# OpenAI
OPENAI_API_KEY=
OPENAI_MODEL_ANALYZER=gpt-4.1-mini
OPENAI_MODEL_COMPOSER=gpt-4.1
OPENAI_MODEL_VOICE=gpt-4.1-mini

# Twilio (WhatsApp + SMS)
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_WHATSAPP_FROM=
TWILIO_SMS_FROM=

# Vapi (voz)
VAPI_API_KEY=
VAPI_ASSISTANT_ID=
VAPI_WEBHOOK_SECRET=

# Deepgram / ElevenLabs (vía Vapi)
DEEPGRAM_API_KEY=
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=

# Email
RESEND_API_KEY=

# App
AGENT_BASE_URL=
POLICY_VERSION=1
TZ=America/El_Salvador
```

Todo webhook entrante **debe** verificar firma antes de procesar (Twilio signature,
Vapi secret). No saltarse esto "por ahora".

---

## 19. Convenciones de código

- **TypeScript estricto.** `strict: true`. Sin `any`. Sin `@ts-ignore`.
- **Zod** para todo límite externo: webhooks, salidas del LLM, YAML de políticas.
  Si un dato cruza un límite de proceso, se valida.
- **Sin lógica de negocio en route handlers.** Los handlers parsean, delegan y
  responden.
- **Sin lógica de negocio en prompts.** Los prompts describen; `packages/core` decide.
- Nombres de dominio en **inglés** en el código (`risk_score`, `commitment`);
  **español** en todo lo que ve el usuario final y el dashboard.
- Fechas: siempre `America/El_Salvador` en la frontera de UI/conversación; `timestamptz`
  UTC en la DB. Usar `date-fns-tz`. Nunca `new Date()` sin zona horaria explícita.
- Dinero: `numeric` en Postgres, enteros en centavos o `Decimal` en TS. **Nunca
  `float` para dinero.**
- Errores: nunca tragar una excepción en el pipeline. Persistir en `events` con
  `error` y degradar a plantilla segura.

---

## 20. Manejo de errores

| Falla | Comportamiento |
|---|---|
| STT | Reintento; si persiste, pedir repetición una vez, luego escalar |
| LLM | Fallback a plantilla segura de la etapa. Nunca improvisar. |
| TTS | Fallback de proveedor o cierre seguro |
| Supabase write | **No confirmar nada al cliente.** Registrar error, reintentar, escalar. |
| Datos inconsistentes | No ejecutar la acción. Escalar. |
| Timeout de tool en Vapi | Responder con un error tipado; Vapi tiene frase de espera |

El caso que **nunca** puede ocurrir:

```
Cliente:  "Entonces queda para el viernes."
Agente:   "Sí, queda registrado."
Supabase: ❌ sin registro
```

---

## 21. Fuera de alcance del MVP

**No construir, no proponer, no empezar:**

modelo de ML entrenado · integración bancaria real · pagos o links de pago reales ·
multi-tenant · roles y permisos · framework de A/B testing · voz entrante ·
multi-idioma · fine-tuning · RAG sobre documentos de política (la inyección directa
basta) · colas tipo BullMQ · almacenamiento de grabaciones · pipeline de redacción
de PII · consola completa de agente humano · tests de UI.

Si una tarea empuja hacia esta lista, decirlo y proponer la versión mínima.

---

## 22. Plan de construcción

```
H0–4    Supabase: schema + seed + cohorte de control
H4–10   packages/core: risk, policy, NBA, guardrails + tests    ← PRIMERO
H10–18  Pipeline WhatsApp end-to-end (Twilio Sandbox)
H18–24  Dashboard: KPIs + cola de riesgo + timeline + Realtime
H24–30  Vapi consumiendo la MISMA Tool API
H30–34  Los 5 escenarios + ajuste de prompts
H34–38  Grabación de respaldo + ensayo del pitch
H38–40  Buffer
```

**`packages/core` va primero.** Es lo que ambos canales comparten y lo que hace que
el proyecto sea defendible técnicamente. Construir el canal antes que el core lleva
a reglas de negocio dispersas en prompts.

**Congelamiento de funcionalidad en la hora 34.** Es parte del plan, no un accidente.

---

## 23. Riesgos conocidos

| # | Riesgo | Mitigación |
|---|---|---|
| 1 | Telefonía en el venue (wifi, ruido) | Vapi **web widget**, no PSTN + **video de respaldo grabado la noche anterior** |
| 2 | WhatsApp: aprobación, ventana de 24h | Twilio Sandbox; join codes el día antes |
| 3 | Dos cerebros divergiendo | Tool API compartida desde la hora 1 |
| 4 | Parseo de fechas ES-SV / UTC-6 | Resolución determinista; el LLM nunca calcula fechas |
| 5 | P95 > 2s en voz | `gpt-4.1-mini`, `max_tokens: 60`, contexto precargado, writes asíncronos |
| 6 | LLM inventa cifras | Grounding numérico en el guardrail |
| 7 | Confirmar sin persistir | Regla del `Receipt` |
| 8 | ngrok cambia de URL | Dominio ngrok reservado |
| 9 | Demo no reproducible | `pnpm demo:reset` + seed determinista |
| 10 | Rate limits de OpenAI en vivo | Caché del escenario dorado como fallback |

---

## 24. Reglas para Claude en este repositorio

1. **Leer este archivo antes de proponer arquitectura.** Las decisiones de §2 están
   cerradas.
2. **Nunca poner reglas de negocio en un prompt.** Van en `packages/core/src/policy`
   o en `policies/*.yaml`.
3. **Nunca dar al LLM permisos de escritura.** El pipeline es: propone → autoriza →
   escribe (determinista).
4. **Nunca dejar que el LLM calcule fechas o montos.** Extrae texto; el código resuelve.
5. **`packages/core` no hace I/O.** Sin `fetch`, sin cliente de Supabase, sin SDK de
   OpenAI. Si hace falta red, está en el lugar equivocado.
6. **Todo dato externo se valida con Zod** — webhooks, salidas del LLM, YAML.
7. **Cada decisión del agente se persiste con sus `ruleIds`.** Sin auditoría, la
   funcionalidad no está terminada.
8. **Optimizar para la demo, no para producción.** Ante la duda entre "correcto para
   producción" y "confiable en el escenario", elegir confiable.
9. **No agregar dependencias sin necesidad clara.** Cada paquete es superficie de fallo.
10. **Datos ficticios siempre.** Nunca generar nada que parezca un cliente real de
    Bancoagrícola, ni números de cuenta con formato realista.
11. **Español para el usuario, inglés para el código.**
12. **Si algo está en §21 (fuera de alcance), decirlo y proponer la versión mínima.**

---

## 25. Referencias

- `README.md` — propuesta original y guion del pitch
- `docs/DEMO-RUNBOOK.md` — guion paso a paso de la demo
- `docs/SCENARIOS.md` — los 5 escenarios de conversación
- `policies/bancoagricola.v1.yaml` — políticas activas

Documentación externa a validar contra la versión vigente al desplegar:
Vapi (latencia, custom tools) · Deepgram Flux (streaming) · ElevenLabs Flash ·
Supabase (Realtime, RLS) · Twilio (WhatsApp Sandbox) · OpenAI (Structured Outputs).

---

**Estado:** prototipo de hackathon · datos ficticios · no representa una decisión
crediticia real · los objetivos de latencia deben comprobarse por medición, no por
estimación del proveedor.
