# Web — Centro de Control de Prevención (paso a paso)

> Para: las 2 personas de web · Stack: Next.js (App Router) + Tailwind + shadcn/ui + Recharts + `@supabase/supabase-js`
> Marcas: ✅ existe hoy en Supabase · 🆕 lo agrega la migración 1200 (Motor de Prevención)

## Idea en una línea

La web **no** es un dashboard de analítica. Es el lugar donde el banco ve **quién necesita ayuda, por qué, qué hacer
con cada persona**, lanza la corrida, **ve a la IA decidir en vivo** y mide **cuánta mora se evitó**.

```
1. RADAR / CENTRO DE PREVENCIÓN   ¿a quién atender y qué hacer?        → "Iniciar corrida" / "Empezar llamada"
2. FICHA "¿POR QUÉ?"              perfil financiero + intervención recomendada + plan
3. INTERVENCIÓN EN VIVO           la IA decidiendo turno a turno
4. IMPACTO Y APRENDIZAJE          compromisos, mora potencialmente evitada, qué funcionó
5. CONFIGURACIÓN                  reglas, ofertas, playbooks, educación (lo que controla el negocio)
```

**Reparto:**
- **Web A:** pantallas 1, 2 y 3 (operación en vivo).
- **Web B:** pantallas 4 y 5 + página pública de pago y cápsulas educativas.

---

## Paso 0 — Setup (30 min, ambos)

- [ ] `npx create-next-app@latest apps/web --ts --tailwind --app` · `npx shadcn@latest init` · `npm i @supabase/supabase-js @supabase/ssr recharts`
- [ ] `.env.local`:
  ```env
  NEXT_PUBLIC_SUPABASE_URL=https://virurjsqumurwrayztcs.supabase.co
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
  AGENT_BASE_URL=https://<servidor-del-agente>        # para "Empezar llamada" / "Iniciar corrida"
  ```
  ⚠️ **Nunca** usar la service role key en la web. La web lee con login (rol `authenticated`).
- [ ] Crear un usuario en Supabase → Authentication (ej. `ventas@demo.test`) y una pantalla de login simple.
  Sin login, RLS devuelve todo vacío.
- [ ] Un cliente Supabase para servidor y otro para navegador (`@supabase/ssr`).
- [ ] Probar la conexión: `supabase.from('v_kpis').select('*').single()` debe devolver 1 fila.

## Paso 1 — Datos disponibles (leer antes de maquetar)

| Necesito… | Fuente | Estado |
|---|---|---|
| KPIs generales | `v_kpis` | ✅ |
| Lista de clientes con riesgo, top 3 factores, señales | `v_customer_overview` | ✅ |
| Distribución de riesgo | `v_risk_distribution` | ✅ |
| Llamadas en curso | `v_live_conversations` + Realtime | ✅ |
| Línea de tiempo de una conversación | `v_conversation_timeline` | ✅ |
| Rendimiento por canal / regla / oferta / etapa / modelo | `v_channel_performance`, `v_rule_performance`, `v_offer_performance`, `v_stage_funnel`, `v_model_performance` | ✅ |
| Intervenidos vs grupo de control | `v_prevention_impact` | ✅ (⚠️ ilustrativo) |
| **Calificación preventiva A–E** + categoría SSF | `v_prevention_center` | 🆕 |
| **Perfil financiero** (pago habitual, monto promedio, último pago, canal que mejor responde…) | `v_customer_financial_profile` | 🆕 |
| **Next Best Intervention** (acción, canal, por qué, plan, oferta, educación, probabilidades) | `rpc('next_best_intervention', {p_customer_id})` | 🆕 |
| **Corrida** (recalcular y priorizar con datos actuales) | `rpc('run_prevention', {p_filters})` → `prevention_runs` | 🆕 |
| Plan de intervención por pasos y su avance | `intervention_steps` | 🆕 |
| Cápsulas educativas | `education_contents`, `education_deliveries` | 🆕 |
| **Mora potencialmente evitada ($)** + "qué funcionó" | `v_impact`, `v_learning` | 🆕 |

> Mientras no exista la migración 1200: maqueten con `v_customer_overview`. Grado A–E = banda
> (BAJO→A, MODERADO→B, PREVENTIVO→C, ALTO→D, CRÍTICO→E) y "acción" = `intervention_status`.

**Contrato 🆕 que devolverá `next_best_intervention`** (para tipar desde ya):
```ts
type NextBestIntervention = {
  customer_id: string
  grade: 'A'|'B'|'C'|'D'|'E'            // calificación preventiva (comportamiento, hacia adelante)
  ssf_category: string                  // A1…E según días de atraso (regulatoria, hacia atrás)
  risk_score: number                    // 0-100 (NO es porcentaje)
  probability_default: number           // 0-1 (esto sí es probabilidad estimada)
  action: 'CALL_NOW'|'WHATSAPP'|'CALL_ALTERNATIVE_DATE'|'EDUCATION_REMINDER'|'HUMAN'|'MONITOR'|'BLOCKED'
  channel: 'voice'|'whatsapp'|'human'|null
  why: string[]                         // "3 pagos tardíos recientes", "vence en 5 días"…
  why_channel: string                   // "Contesta 4 de 5 llamadas; WhatsApp 1 de 4"
  propensity: { voice: number; whatsapp: number; education: number }  // tasas observadas con suavizado
  offers: { code: string; name: string }[]
  education: { slug: string; title: string; duration_s: number } | null
  plan: { step: number; type: string; label: string; scheduled_for: string|null }[]
  amount_at_risk: number
  expected_avoided_amount: number       // estimación
  blocked_reason: string|null
}
```

---

## Paso 2 — Layout y navegación (Web A, 30 min)

- [ ] Sidebar: **Centro de Prevención** · **En vivo** (con contador rojo de llamadas activas) · **Impacto** · **Configuración**.
- [ ] Header: nombre del producto, badge "Datos ficticios · demo", fecha de hoy (America/El_Salvador).
- [ ] Botones globales: **Iniciar corrida** (Paso 3) y, discreto, **Reset demo** (solo en desarrollo).

## Paso 3 — Pantalla 1: Centro de Prevención (Web A, 3–4 h) ⭐

**Arriba, tarjetas:**
- 🔴 **N clientes requieren intervención** (grados C, D, E no bloqueados)
- 💰 **$X en pagos potencialmente prevenibles** (suma de `amount_at_risk`)
- 🧪 **Grupo de control:** N (no se contactan, sirven para medir)
- 🚫 **Bloqueados por regla:** N (disputa, opt-out, frecuencia). Muestra que las reglas protegen al cliente.

**Distribución A–E:** barra apilada o 5 chips (A verde → E rojo) con conteo. Clic = filtro.

**Tabla priorizada** (ordenada por prioridad = riesgo × monto × cercanía):

| Cliente | Grado | Riesgo | Vence | Monto | Acción recomendada | Canal | Por qué (1 línea) | |
|---|---|---|---|---|---|---|---|---|
| Carlos Martínez | **D** | 74 | 2 días | $191 | 📞 Llamar + fecha alternativa | Voz | 6 pagos tardíos · salario atrasado | [Empezar llamada] |

- [ ] Iconos por acción: 📞 `CALL_NOW` · 📞📅 `CALL_ALTERNATIVE_DATE` · 📱 `WHATSAPP` · 🎓 `EDUCATION_REMINDER` · 👤 `HUMAN` · 👁 `MONITOR` · 🚫 `BLOCKED`
- [ ] Filtros: grado, acción, canal, producto, departamento, "solo contactables".
- [ ] Clic en la fila → Pantalla 2.

**Botón "Iniciar corrida"** (el momento wow #1):
1. Modal con filtros (grados C–E, días a vencer ≤ 10, excluir bloqueados; control excluido siempre).
2. `rpc('run_prevention', { p_filters })` → muestra **preview**: "47 intervenciones: 18 llamadas, 21 WhatsApp, 6 educación, 2 humano · 3 bloqueados · 12 grupo de control".
3. Confirmar → `POST {AGENT_BASE_URL}/runs/{run_id}/dispatch`.
4. Toast: "3 llamadas reales iniciadas · 15 simuladas (sin número habilitado)". Redirigir a **En vivo**.

**Botón "Empezar llamada"** (por fila): `POST {AGENT_BASE_URL}/calls/{customer_id}` → abre Pantalla 3 de esa conversación.
Deshabilitado con tooltip si el cliente no es contactable o está bloqueado (mostrar la razón).

## Paso 4 — Pantalla 2: Ficha "¿Por qué estamos contactando a…?" (Web A, 2–3 h) ⭐

Tres columnas en escritorio; apiladas en móvil:

**A. Perfil financiero** (`v_customer_financial_profile` 🆕)
```
Pago habitual        día 15 de cada mes
Monto promedio       $420      Último pago   $310 (−26%)
Retrasos recientes   3 de 6    Tendencia     empeorando ↓
Canal que responde   Voz (4/5)  Mejor horario tarde
Grado  D  ·  Categoría SSF  A1  ·  Riesgo 74/100 · Prob. de mora 58%
```
⚠️ Mostrar **riesgo 74/100** y **probabilidad 58%** por separado. No escribir "74%": un jurado de banco lo detecta.

**B. ¿Por qué?**
- Top factores (`top_factors` con puntos) como barras horizontales + señales (`active_signals`) como chips.
- Reglas activadas (nombres legibles) y, si aplica, **bloqueos** en rojo con su razón.

**C. Intervención recomendada** (`next_best_intervention` 🆕)
- Acción grande (ej. "📞 LLAMADA PREVENTIVA") + `why_channel` ("históricamente contesta llamadas").
- Barras de propensión voz / WhatsApp / educación (etiqueta: "tasa observada").
- Ofertas permitidas (máx. 3) con su nombre.
- **Plan de intervención** como stepper vertical (`plan`):
  `1 📞 Llamada → 2 🧠 Identificar situación → 3 💬 Alternativa autorizada → 4 🤝 Compromiso → 5 📱 WhatsApp con link → 6 🎓 Cápsula → 7 🔔 Recordatorio antes de la fecha`
  Cada paso con estado (pendiente / hecho / programado) desde `intervention_steps` 🆕, que se actualiza en vivo.
- Botón **Empezar llamada** / **Enviar WhatsApp**.

**Abajo:** historial de conversaciones (fecha, canal, resultado, resumen) → clic abre la línea de tiempo.

## Paso 5 — Pantalla 3: Intervención en vivo (Web A, 3–4 h) ⭐⭐ (el momento wow #2)

Suscripciones Realtime filtradas por `conversation_id`:
```ts
supabase.channel(`conv-${id}`)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `conversation_id=eq.${id}` }, onMessage)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'turn_evaluations', filter: `conversation_id=eq.${id}` }, onEval)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'conversation_events', filter: `conversation_id=eq.${id}` }, onEvent)
  .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversations', filter: `id=eq.${id}` }, onConv)
  .subscribe()
```

**Layout:**
```
┌ 🔴 LLAMADA EN CURSO · Carlos Martínez · Grado D · 01:24 ─────────────────────────┐
│ TRANSCRIPCIÓN (izq.)              │ CEREBRO (der.)                               │
│ 🤖 Buenos días, Carlos…           │ Etapa:  ● ● ● ◉ ○ ○ ○  PROPUESTA             │
│ 👤 Este mes ando complicado       │ Intención:   Dificultad financiera           │
│ 🤖 Tengo una opción… ✂️ interrump.│ Sentimiento: Preocupado  (−0.35)             │
│ 👤 ¿Cuánto dijo?                  │ Ritmo:       Lento                           │
│                                   │ Regla:       "Situación entendida"           │
│                                   │ Siguiente:   Proponer fecha alternativa      │
│                                   │ Política:    ✓ Dentro de límites (≤ 7 días)  │
│                                   │ ⚠️ Condiciones interrumpidas → repetir       │
│                                   │ Latencia:    1.24 s   · Costo: $0.012        │
└───────────────────────────────────────────────────────────────────────────────────┘
```
- [ ] Transcripción desde `messages`; si `interrupted=true`, mostrar ✂️ y `heard_text` en gris ("lo que alcanzó a escuchar").
- [ ] Cerebro desde el último `turn_evaluations`: `to_stage`, `intent`, `sentiment`, `pace`, `rule_label`, `decision`.
- [ ] Stepper de etapas del playbook (`playbook_stages` ordenadas por `position`).
- [ ] "Política ✓" desde eventos `offer_validated` / `offer_rejected` (mostrar el error legible si fue rechazada: "Excede máximo de 7 días").
- [ ] Eventos destacados como toasts: `commitment_registered` (🤝 + recibo), `escalation_created`, `handoff_created` (📱), `interruption_real`, `opt_out_registered`.
- [ ] Latencia: último `messages.latency_ms` del agente. Costo: `conversations.cost_usd`.
- [ ] Al terminar: tarjeta de cierre con resultado, **riesgo antes → después** y siguiente paso del plan.
- [ ] Vista `/en-vivo` (lista): `v_live_conversations` con tarjetas pequeñas; clic → detalle.
- [ ] `/conversaciones/[id]` para las ya terminadas: `v_conversation_timeline` ordenada por `at`.

## Paso 6 — Pantalla 4: Impacto y aprendizaje (Web B, 3 h)

**Tarjetas:** clientes intervenidos · compromisos · tasa de compromiso · monto comprometido · **💰 Mora potencialmente evitada** (`v_impact` 🆕) · P95 de respuesta (`v_kpis.p95_voice_latency_ms`) · costo por intervención.

- [ ] Tooltip obligatorio en "mora potencialmente evitada": *"Estimación: monto en riesgo × (probabilidad de mora sin intervención − con compromiso). Datos ficticios."*
- [ ] **Intervenidos vs grupo de control** (`v_prevention_impact`): 2 barras de tasa de mora + nota "simulación ilustrativa".
- [ ] **¿Qué funcionó?** (`v_learning` 🆕): matriz grado × canal con tasa de compromiso (heatmap). Debajo, en texto: "Grado D + voz: 61% · Grado C + WhatsApp: 74%".
  Este es el **closed loop**: la misma tasa alimenta la propensión de `next_best_intervention`.
  En la demo, después de una llamada real, refrescar y ver que el número cambia.
- [ ] Por regla (`v_rule_performance`), por oferta (`v_offer_performance`), embudo por etapa con tasa de interrupción (`v_stage_funnel`).
- [ ] Serie diaria (`v_daily_metrics`) y cambio de sentimiento (`v_sentiment_shift`).
- [ ] Laboratorio (pestaña): `v_model_performance` (latencia, costo y compromiso por modelo).

## Paso 7 — Pantalla 5: Configuración "lo que controla el negocio" (Web B, 3–4 h)

- [ ] **Reglas** (`collection_rules` + `rule_offers`): lista con interruptor activo/inactivo y prioridad.
  Editor de condiciones con filas `hecho · operador · valor` generadas desde `rule_fact_definitions`
  (el tipo define el input: número, enum → select, lista → multiselect).
  Guardar como JSON `{"all":[{"fact","op","value"}]}`.
  - Botón **"Probar con cliente"**: select de cliente → `rpc('match_rules', {p_customer_id})` → muestra reglas activadas, ofertas y bloqueos. *(Momento wow #3: cambiar una regla y ver cambiar la recomendación.)*
- [ ] **Ofertas** (`offers`): nombre, tipo, parámetros (JSON simple), plantilla de condiciones con preview, "requiere aprobación".
- [ ] **Playbooks** (`playbook_stages`): etapas en orden con objetivo, instrucciones y criterios (chips desde `evaluation_criteria`). Reglas de salida en JSON por ahora.
- [ ] **Educación** 🆕 (`education_contents`): título, duración, link de video, guion, condición de a quién aplica.
- [ ] **Políticas** (`agent_policies`): límites (máx. ofertas, turnos, contactos/semana), frases prohibidas, bandas de riesgo.
- [ ] **Aprobaciones**: `commitments` con `status='pending_approval'` → botones Aprobar/Rechazar (update a `approved`/`cancelled`).
- [ ] **Escalaciones**: `escalations` abiertas → asignar / resolver.

## Paso 8 — Páginas públicas (Web B, 1–2 h)

- [ ] `/pagar/[token]` sin login: `rpc('get_payment_link', {p_token})` → "Hola Carlos · $38.19 · Pagar" → `rpc('simulate_payment', {p_token})` → ✅ recibo.
  Estilo sobrio; decir "pago simulado". **No** usar logos ni marcas de terceros (bancos, billeteras) como si estuvieran integrados.
- [ ] `/aprende/[slug]` 🆕: cápsula de 15–20 s (video o tarjetas animadas) + botón "Entendido" → registra `education_deliveries.viewed_at`. El link llega por WhatsApp.

## Paso 9 — Ensayo de la demo (ambos, 1 h)

```
0:00  Centro de Prevención: 162 clientes → "Iniciar corrida" → 47 requieren intervención · $X prevenibles
0:30  Clic Carlos → "¿Por qué?" (perfil financiero, factores) → intervención recomendada y plan
0:50  Configuración: cambiar una regla → "Probar con cliente" → cambia la recomendación
1:10  "Empezar llamada" → suena el teléfono → Intervención en vivo (etapas, intención, política, latencia)
2:20  Interrupción durante condiciones → ⚠️ → el agente repite → 🤝 compromiso con recibo
2:40  📱 Llega WhatsApp con link → /pagar → ✅ → el plan marca pasos hechos → 🎓 cápsula
3:00  Impacto: mora potencialmente evitada, qué funcionó (el número cambió con esta llamada)
```
- [ ] Antes de cada ensayo: `select reset_demo();` desde el SQL editor (vía RPC puede tardar).
- [ ] Habilitar el teléfono de la demo: `select set_demo_contact('DEMO-001','+503…');`.

## Errores comunes a evitar

- Consultas vacías → no hay sesión iniciada (RLS).
- Realtime sin eventos → falta el filtro por id o la tabla no está en la publicación (las de arriba ya lo están).
- Mostrar `risk_score` como porcentaje.
- Hacer cálculos de negocio en el front (riesgo, elegibilidad, ofertas): **siempre** desde la BD.
- Poner la service role key en `NEXT_PUBLIC_*`.
