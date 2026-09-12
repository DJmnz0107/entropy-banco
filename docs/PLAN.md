# Plan — Cobranza preventiva con control de conversación

> Documento vivo. Si cambia algo, se actualiza aquí y en `CLAUDE.md`.

## 1. La idea, ordenada

```
DATOS (seed)                      ─┐
REGLAS que configura ventas (web) ─┼─► DETECCIÓN ─► INTERVENCIÓN (decisión antes de contactar)
RIESGO explicable                 ─┘                     │
                                                         ▼
                                     LLAMADA (voz, con todo el contexto)
                                         │  cada turno: supervisor evalúa criterios
                                         │  controlador decide etapa / ritmo / qué ofrecer
                                         │  interrupciones y negativas se reconocen
                                         ▼
                           CALL TO ACTION con opciones que YA configuró ventas
                                         │
                   ┌─────────────────────┼──────────────────────┐
                   ▼                     ▼                      ▼
             compromiso            siguiente paso          escalamiento / negativa
             (con recibo)          por WhatsApp            respetada
                   │               + link de pago
                   └─────────────────────┬──────────────────────┘
                                         ▼
                      TODO registrado → DASHBOARD en vivo + métricas + logs
```

No se "entrena" el LLM con los datos. El contexto del cliente y las reglas se **inyectan en cada
llamada**. Eso es mejor para el reto: si ventas cambia una regla en la web, la **siguiente llamada**
ya la aplica, sin reentrenar.

## 2. ¿Es un diferenciador?

**Por sí sola, que ventas configure reglas en la web no lo es**: cualquier CRM tiene un constructor de reglas.
**Sí lo es la combinación**, y hay que presentarla así:

1. Las reglas del negocio definen **qué** se puede ofrecer (ofertas) y **cómo** conducir la conversación (etapas con criterios).
2. El LLM queda **limitado en tiempo real** a eso, en voz y en WhatsApp. Si inventa algo, la BD lo rechaza.
3. En cada momento clave se evalúan **criterios distintos**: identidad en la apertura, capacidad de pago en el descubrimiento, confirmación explícita al cierre. Con eso, un controlador decide avanzar, frenar, bajar el ritmo o escalar.
4. Las interrupciones y las negativas **se detectan y se respetan**, y cambian lo que el sistema permite.
5. Quien vende **ve la llamada en vivo**: etapa, evaluación, regla que se disparó y resultado. Además aprende qué regla funciona mejor (`v_rule_performance`).

Frase para el pitch:
> *"Todos usan el mismo modelo. La diferencia no es el modelo: es quién controla la conversación.
> Aquí la controla el negocio, no el LLM."*

## 3. Arquitectura

```
                 ┌──────────────────────── SUPABASE (fuente única) ────────────────────────┐
                 │  datos · reglas · ofertas · playbooks · criterios · modelos · prompts   │
                 │  RPC: start_conversation · evaluate_turn · validate_offer ·             │
                 │       register_commitment · log_interruption · create_handoff · …       │
                 │  Vistas + Realtime                                                      │
                 └───────▲─────────────────────▲─────────────────────────▲─────────────────┘
                         │ secret key          │ secret key              │ publishable + login
               ┌─────────┴────────┐  ┌─────────┴─────────┐   ┌───────────┴────────────┐
               │   VOZ (Josué)    │  │ WHATSAPP (compa)  │   │  WEB (2 personas)      │
               │ Gemini Live      │  │ Twilio Sandbox    │   │ Next.js                │
               │ + supervisor     │  │ + Flash-Lite      │   │ Operación · Config     │
               │   Flash-Lite     │  │ + multimodal      │   │ En vivo · Laboratorio  │
               └──────────────────┘  └───────────────────┘   └────────────────────────┘
```

**Por qué la lógica vive en la base de datos:** son 4 personas, 3 superficies y posiblemente distintos
lenguajes. Si cada uno reimplementa las reglas, en la hora 20 la voz y WhatsApp se comportan distinto.
Con funciones SQL, todos llaman exactamente la misma lógica. Además ya tiene 38 pruebas (`npm run db:test`).

## 4. Voz — cómo lograr una conversación fluida y controlada

### 4.1 Modelos (precios verificados el 12/09/2026)

| Opción | Costo llamada 3 min | Fluidez | Control |
|---|---|---|---|
| **A. Gemini 3.1 Flash Live** (speech-to-speech) | ~$0.03–0.05 · **$0 free tier** | La mejor: un solo salto, barge-in nativo | Tools **bloqueantes**; historial guarda lo enviado, no lo escuchado |
| **B. Gemini 2.5 Flash Native Audio** | ~$0.03–0.05 · $0 free tier | Muy buena + *affective dialog* | Tools **no bloqueantes** (registra sin silencio) |
| **C. Cascada** Deepgram Flux → Flash-Lite → Cartesia Sonic | por verificar | Buena si se optimiza | **Máximo control**: controlador corre entre turnos |
| OpenAI Realtime mini | ~$0.06–0.15 (sin verificar) | Muy buena | Permite truncar el historial a lo que sonó |

**Recomendación:** empezar con **A** y medir **A vs B** (experimento `EXP-VOZ-02`, ya configurado).
Probar **C** solo si A/B fallan en exactitud de fechas o montos con acento salvadoreño.
Cambiar de modelo = editar una fila en `ai_model_profiles` o `agent_policies.default_models`.

**Framework sugerido: LiveKit Agents** (open source, plugin de Gemini Live, manejo de interrupciones, SIP a futuro).
Alternativa: Pipecat. Verificar el soporte vigente del plugin antes de comprometerse.
**Para la demo: llamada por navegador (WebRTC), no telefónica.** Cuesta $0 en telefonía, y hay reportes de
latencias de 5–8 s con Gemini sobre SIP.

### 4.2 Control dentro de una llamada en tiempo real

Gemini Live **no permite cambiar el system prompt** una vez abierta la sesión, e inyectar contexto
**interrumpe al modelo si está hablando**. Por eso el control va en dos niveles:

| Nivel | Qué | Cómo |
|---|---|---|
| **Suave** (dirige) | Etapa, ritmo, qué ofrecer | Supervisor Flash-Lite evalúa cada turno en paralelo → `evaluate_turn` → se inyecta `control_message` **mientras el cliente habla** (el modelo no está generando). Va un turno atrasado, y está bien. |
| **Duro** (protege) | Compromisos, links, escalamiento | Tools que llaman RPC. La BD **rechaza** lo que esté fuera de política, sin importar lo que diga el modelo. |

```
al iniciar:
  ctx = rpc start_conversation(cliente, 'voice', experiment_key='EXP-VOZ-02')
  sesión Gemini Live con: system = prompt voice.system renderizado con ctx
                          vad = ctx.models.voice_realtime.vad_config
                          tools = validar_oferta, registrar_compromiso, enviar_seguimiento_whatsapp, escalar_a_humano
                          input/output transcription = on

turno del agente terminado  → log_message(agent, texto, {latency_ms, audio_ms})
turno del cliente terminado → m = log_message(customer, texto)
                              en paralelo: sc = supervisor(último intercambio, criterios de la etapa)
                                           d  = evaluate_turn(conv, sc, m)
                                           inyectar d.control_message cuando el modelo NO esté hablando
                                           si d.decision ∈ {end, escalate}: dejar que se despida → end_conversation
server.interrupted          → ver 4.3
tool call                   → RPC correspondiente → devolver JSON al modelo
silencio > 6 s              → log_silence → inyectar
usageMetadata               → record_model_usage
```

### 4.3 Interrupciones (lo que pasa en la vida real)

Dato clave del protocolo: tras una interrupción, Gemini **conserva lo que se ENVIÓ, no lo que SONÓ**.
El cliente puede haber oído "3 cuotas" y el modelo creer que dijo "3 cuotas con 20% de pago inicial".

| Situación | Detección (cliente) | Acción |
|---|---|---|
| "ajá", "mjm", "sí" | Texto en `backchannel_phrases` y < 700 ms | `log_interruption('backchannel')` → continuar |
| Pregunta o corrección | Voz real > 400 ms | `log_interruption('real', heard_text, played_ms)` → inyectar instrucción: responder, no reiniciar |
| **Interrumpe durante condiciones** | `real` en PROPUESTA/COMPROMISO/CONFIRMACION | La BD marca la oferta como no escuchada → **`register_commitment` falla** hasta que se repita |
| Ruido (tele, niños, campo) | Interrupción sin transcripción en 1.2 s | `log_interruption('false_barge_in')` → "Disculpe, le decía…" |
| Silencio | 6 s sin voz | `log_silence` ×2 → cerrar y mandar WhatsApp |
| "No me vuelvan a llamar" | Scorecard | La BD registra opt-out y cierra con respeto |

`heard_text`: estimar con la proporción de audio reproducido (`played_ms / total_ms`) sobre la transcripción de salida.

Si con VAD automático los "ajá" cortan demasiado al agente → pasar a **VAD manual**. Con VAD manual, el cliente decide
cuándo mandar `activityStart`, lo que da control total a cambio de más trabajo. Se mide con `EXP-VAD-01`.

### 4.4 Iterar sin gastar

1. **Texto primero:** los 13 `eval_scenarios` (incluyen interrupción, asentimientos, ruido, tercero, opt-out) se corren con
   un cliente simulado (Flash-Lite, temp 0.9) contra supervisor + controlador. Cuestan centavos.
   Validan etapas, reglas y ofertas.
2. **Voz después:** solo para latencia, interrupciones y calidad de voz. Se graba cada prueba.
3. **Todo queda medido:** `v_model_performance`, `v_stage_funnel` (dónde interrumpen) y `eval_runs`.

## 5. Reparto del trabajo

### Josué — Voz
1. Google AI Studio → API key → probar Gemini 3.1 Flash Live en español con una voz (verificar cuál suena mejor).
2. Agente LiveKit (o Pipecat) con el loop de 4.2 contra `DEMO-001`.
3. Supervisor asíncrono + inyección de `control_message`.
4. Interrupciones (4.3) + `log_interruption`.
5. Tools → RPC. Handoff a WhatsApp al cerrar.
6. Medir A vs B; grabar llamada de respaldo para el pitch.

### Compañero — WhatsApp
1. Twilio → WhatsApp Sandbox → unir los teléfonos del equipo (**el día antes**). Verificar las reglas de la ventana de 24 h para mensajes iniciados por el negocio.
2. Webhook entrante → `find_customer_by_phone` → `start_conversation('whatsapp','inbound')`.
3. Escuchar `handoffs` (Realtime, `to_channel='whatsapp'`) → `claim_handoff` → mensaje con link y resumen.
4. Loop por mensaje: `log_message` → supervisor → `evaluate_turn` → composer (`composer.whatsapp` + `control_message`) → tools → enviar.
5. Notas de voz e imágenes → perfil `multimodal`. **Un comprobante nunca confirma un pago.**

### Web A — Operación y analítica
- `/` KPIs (`v_kpis`, `v_prevention_impact`, `v_daily_metrics`, `v_risk_distribution`)
- `/en-vivo` llamadas activas + transcripción en tiempo real (Realtime)
- `/conversaciones/[id]` línea de tiempo (`v_conversation_timeline`)
- `/clientes` cola de riesgo con top factores (`v_customer_overview`)
- `/escalaciones` y aprobación de compromisos
- `/pagar/[token]` página pública de pago (anon)
- Botones: **Ejecutar detección** (`run_detection`) y **Reset demo**

### Web B — Configuración y control ("lo que configura ventas")
- `/reglas` constructor de condiciones desde `rule_fact_definitions` + ofertas ordenadas + **"Probar con cliente"** (`match_rules`)
- `/ofertas` catálogo con condiciones y script
- `/playbooks` etapas: objetivo, guion, criterios y reglas de salida
- `/politicas` interrupciones, ritmo, límites, frases prohibidas
- `/laboratorio` modelos, prompts versionados, experimentos (`v_model_performance`, `v_stage_funnel`)

## 6. Herramientas a iniciar HOY

| # | Herramienta | Quién | Para qué | Costo |
|---|---|---|---|---|
| 1 | **Supabase** con acceso al proyecto | Josué | Subir BD (autorizar el plugin o pasar `SUPABASE_DB_URL`) | Free |
| 2 | **Google AI Studio** → API key Gemini | Voz + WhatsApp | Voz, supervisor, composer, multimodal | Free tier |
| 3 | **LiveKit Cloud** (o Pipecat local) | Josué | Framework de voz | Free tier |
| 4 | **Twilio** + WhatsApp Sandbox | Compañero | Canal WhatsApp | Créditos de prueba |
| 5 | **ngrok** con dominio reservado | Compañero | Webhook de Twilio estable | Free |
| 6 | **Vercel** | Web | Deploy del dashboard | Free |
| 7 | Deepgram + Cartesia (opcional) | Josué | Solo si se prueba la cascada | Créditos gratis |
| 8 | Node 22 + pnpm, Supabase CLI | Todos | Ya instalados en la máquina de Josué | — |

## 7. Guion de la demo (3:30)

1. **Detección (0:30).** Dashboard: 162 clientes → "Ejecutar detección" → 61 intervenciones programadas, 3 bloqueadas y 20 en grupo de control. Ficha de Carlos: riesgo 74 con los 3 factores.
2. **Control del negocio (0:50).** Ventas cambia una regla en vivo → "Probar con cliente" → cambian las ofertas de Carlos.
3. **Llamada (1:00).** Voz por navegador con Carlos. Panel en vivo: etapa, scorecard, ritmo. **Carlos interrumpe durante las condiciones** → el panel muestra "condiciones no escuchadas" → el agente las repite.
4. **Cierre (0:40).** Compromiso con recibo → llega el WhatsApp al teléfono con el link → pago en `/pagar` → dashboard: compromiso cumplido, riesgo 74 → 62.
5. **Laboratorio (0:20).** Costo por llamada, latencia P95 y Gemini 3.1 vs 2.5.

⚠️ Decir explícitamente que los datos son **ficticios**, que la comparación intervenido vs control es **ilustrativa**
(fue generada) y que el riesgo es un modelo ponderado demostrativo.

## 8. Riesgos

| Riesgo | Mitigación |
|---|---|
| Wifi del venue en la llamada | Navegador, no PSTN + **video de respaldo** |
| Twilio Sandbox / ventana 24 h | Unir teléfonos el día antes; probar mensaje iniciado por el negocio |
| Gemini Live corta con "ajá" | VAD baja sensibilidad → si no alcanza, VAD manual |
| Tools bloqueantes (3.1) dan silencio | Pocas tools, rápidas; frase de espera; comparar con 2.5 no bloqueante |
| Fechas "el viernes" mal resueltas | Resolver en código con `America/El_Salvador`; el LLM solo extrae el texto |
| `reset_demo` hace timeout vía RPC | Correrlo desde el SQL editor |
| Modelos preview cambian | IDs en BD, no en código; `pricing_verified_at` visible |

## 9. Fuera de alcance

ML entrenado · fine-tuning · integración bancaria real · pagos reales · telefonía PSTN en la demo · voz entrante ·
multi-idioma · RAG · colas de mensajes · consola completa de agente humano · tests de UI.
