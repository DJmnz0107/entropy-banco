# Tarea para Claude — Handoff proactivo de Voz a WhatsApp

## Objetivo

Implementar de punta a punta el flujo **voz primero → WhatsApp como continuación**, de forma que el cliente no tenga que pedir espontáneamente “mándemelo por WhatsApp”. Durante la llamada, el agente debe sugerir WhatsApp una sola vez, pedir consentimiento explícito y crear un `handoff`. Como la demo no contará con una plantilla aprobada de Meta, debe pedir al cliente que envíe la palabra **CONTINUAR** al WhatsApp del banco; ese mensaje entrante abre la ventana de servicio y el bot responde inmediatamente con el resumen, comprobante, enlace de pago u opciones correspondientes.

La experiencia objetivo es:

```text
Llamada preventiva
→ el agente comprende la situación
→ negocia o define el siguiente paso
→ propone continuar por WhatsApp
→ el cliente acepta
→ se registra un handoff auditable
→ termina la llamada
→ el cliente envía “CONTINUAR” al WhatsApp del banco
→ el bot reclama el handoff y responde con el contenido correcto
→ el cliente abre el enlace o continúa la conversación
→ la web muestra todo en tiempo real
```

## Repositorios y estado actual

- Backend, agente, bot y migraciones: `/Users/rafaelsandoval/dev/entropy-banco`
- Dashboard: `/Users/rafaelsandoval/dev/web-banco`
- El agente corre con Hono + TypeScript, ElevenLabs y Gemini.
- El bot de WhatsApp está en `backend/whatsapp-hackathon-bot` y usa Meta Cloud API.
- Supabase es la fuente única de verdad.
- Ya existen la tabla `handoffs` y las RPC `create_handoff`, `claim_handoff` y `complete_handoff`.
- `create_handoff(..., 'whatsapp', 'SEND_PAYMENT_LINK')` ya puede crear el payment link e incluir compromiso, payload y resumen.
- El agente de voz actualmente ofrece `enviar_por_correo`; no posee una herramienta completa para WhatsApp.
- El bot actualmente procesa mensajes entrantes, pero no consume handoffs pendientes.
- La web ya muestra eventos `handoff_created` y escucha cambios relevantes por Realtime.

Antes de editar, revisa `CLAUDE.md`, `INSTRUCTIONS.md`, `docs/CONTRATO-API.md` y los archivos involucrados. Ejecuta `git status` en ambos repositorios y preserva todos los cambios existentes. No uses `git reset`, `git checkout --` ni sobrescribas trabajo ajeno.

## Principio de producto

WhatsApp debe ser una **continuación conveniente**, no un envío forzado.

- El agente propone WhatsApp proactivamente; no espera que el cliente lo mencione.
- Solo crea el handoff cuando el cliente acepta explícitamente, salvo el caso especial de llamada no contestada descrito abajo.
- Nunca envía WhatsApp a clientes con opt-out, sin consentimiento de WhatsApp, sin teléfono habilitado, en grupo de control o bloqueados por política.
- Nunca dice “ya se lo envié” antes de recibir confirmación real de creación/ejecución.
- Una negativa a WhatsApp se respeta y no se vuelve a ofrecer en esa llamada.
- No se debe duplicar contenido por WhatsApp y correo. WhatsApp será el canal preferente cuando el cliente lo acepte; correo será fallback si el handoff falla o WhatsApp no está permitido.
- Sin una plantilla aprobada, el banco no intentará iniciar el chat. El handoff queda pendiente hasta que el cliente escriba y abra la ventana de atención de 24 horas.
- Aceptar verbalmente WhatsApp no abre por sí solo esa ventana; la llamada debe explicar el siguiente paso.

## Cuándo debe sugerir WhatsApp

### A. Compromiso registrado

Después de obtener un `receipt_code`, sugerir:

> “¿Le envío por WhatsApp el comprobante y el enlace para que lo tenga a mano?”

Si acepta, crear `SEND_PAYMENT_LINK` cuando corresponda un pago, o `SEND_COMMITMENT_SUMMARY` cuando no deba generarse link o la solicitud esté pendiente de aprobación. Después indicar: “Perfecto. Para proteger su información, escriba CONTINUAR al WhatsApp de Bancoagrícola y recibirá allí su comprobante.”

### B. Cliente interesado, pero sin compromiso

Si el resultado será `FOLLOW_UP_REQUIRED`, el cliente está evasivo, necesita revisar opciones o no tiene tiempo:

> “Si le parece, puedo enviarle por WhatsApp un resumen de las opciones autorizadas para que las revise con calma.”

Si acepta, crear `SEND_OFFER_DETAILS` o `FOLLOW_UP_MESSAGE`.

### C. Rellamada acordada

Cuando se registra `CALLBACK_SCHEDULED`, ofrecer un recordatorio por WhatsApp. Si acepta, crear `CALLBACK` con fecha y franja en el payload.

### D. Escalación humana

Si el cliente pide una persona, se puede ofrecer por WhatsApp únicamente una confirmación genérica del caso y su referencia, sin detalles sensibles. El escalamiento debe ocurrir aunque el cliente rechace WhatsApp.

### E. Llamada no contestada

Sin plantilla aprobada no se puede iniciar WhatsApp después de una llamada no contestada. Usar correo como fallback. Solo será posible responder por WhatsApp si el cliente escribe posteriormente por iniciativa propia.

### F. Casos donde NO se ofrece ni envía

- `DO_NOT_CONTACT`
- Negativa explícita final
- Persona equivocada / tercero
- Posible fraude o disputa cuando el mensaje pueda revelar información financiera
- Falta de consentimiento WhatsApp
- Grupo de control
- Cliente bloqueado por política
- El cliente ya rechazó WhatsApp durante la llamada

## Implementación requerida

### 1. Endurecer el contrato en Supabase

Crear una migración nueva; no modificar migraciones ya aplicadas.

- Revalidar dentro de `create_handoff` o una RPC wrapper específica que el cliente puede recibir WhatsApp.
- Validar `consent_whatsapp`, `contact_enabled`, `opted_out_at`, grupo de control, teléfono y bloqueos aplicables.
- Hacer el alta idempotente: una conversación no debe generar dos handoffs `pending|processing|completed` equivalentes para el mismo `to_channel` y `action`.
- Devolver un resultado explícito con `ok`, `handoff_id`, `action`, `status`, `payload` y error de política cuando aplique.
- Mantener `claim_handoff` atómico para que dos workers no envíen el mismo mensaje.
- Registrar eventos auditables: `whatsapp_handoff_offered`, `whatsapp_handoff_declined`, `handoff_created`, `handoff_completed` y `handoff_failed`.
- Si hace falta ampliar payload o constraints, hacerlo sin romper los datos existentes.

### 2. Agregar herramienta al agente de voz

Archivos principales:

- `apps/agent/src/voice/tools.ts`
- `apps/agent/src/lib/supabase.ts`
- `apps/agent/src/voice/state.ts`
- `apps/agent/src/voice/prompt.ts` y/o prompt activo en una migración nueva
- `apps/agent/src/channels/finalize.ts`

Agregar una herramienta con un nombre claro, por ejemplo `enviar_por_whatsapp` o `crear_seguimiento_whatsapp`.

Parámetros sugeridos:

```ts
{
  accion:
    | 'SEND_PAYMENT_LINK'
    | 'SEND_COMMITMENT_SUMMARY'
    | 'SEND_OFFER_DETAILS'
    | 'FOLLOW_UP_MESSAGE'
    | 'CALLBACK'
  cliente_confirmo_whatsapp: boolean
}
```

Reglas:

- Rechazar la tool call si `cliente_confirmo_whatsapp !== true`.
- Elegir/validar server-side la acción compatible con el estado real; no confiar ciegamente en el argumento del modelo.
- Para `SEND_PAYMENT_LINK` debe existir un compromiso válido y no pendiente de aprobación.
- Para `SEND_COMMITMENT_SUMMARY` debe existir compromiso o solicitud registrada.
- Para `SEND_OFFER_DETAILS` usar únicamente las ofertas congeladas en `context_snapshot`.
- Guardar en el estado si WhatsApp ya fue ofrecido, aceptado, rechazado o encolado, para no repetir la pregunta.
- Después de una respuesta exitosa, el agente puede decir que “lo enviará” o que “quedó programado”; no afirmar que ya llegó hasta que el bot complete el handoff.
- No cerrar la llamada antes de que la RPC confirme que el handoff quedó creado.

### 3. Volver proactiva la sugerencia en el prompt

Actualizar el prompt activo mediante una migración versionada.

Instrucciones necesarias:

- Ofrecer WhatsApp una sola vez al llegar a `SIGUIENTE_PASO` o antes del cierre, según la matriz anterior.
- No esperar las palabras “WhatsApp”, “mensaje” o “envíeme”.
- Hacer una pregunta corta, concreta y opcional.
- No ofrecerlo durante descubrimiento o mientras el cliente expresa una dificultad emocional.
- Primero resolver o registrar el siguiente paso; después ofrecer el canal.
- Si acepta, llamar inmediatamente a la herramienta.
- Después de crear el handoff, indicar brevemente que debe escribir **CONTINUAR** al WhatsApp del banco. No decir que el mensaje ya fue enviado.
- Si rechaza, agradecer y cerrar sin insistir.
- No sustituir el consentimiento con frases ambiguas como “está bien” si no responden claramente a la pregunta de WhatsApp.

### 4. Consumidor de handoffs en el bot de WhatsApp

Archivos principales:

- `backend/whatsapp-hackathon-bot/index.js`
- `backend/whatsapp-hackathon-bot/supabase.js`
- `backend/whatsapp-hackathon-bot/whatsapp.js`
- un módulo nuevo como `handoffs.js` si ayuda a separar responsabilidades

Implementar un consumidor seguro activado principalmente por mensajes entrantes:

1. Cuando llegue cualquier mensaje —especialmente `CONTINUAR`— identificar primero al cliente por teléfono.
2. Buscar su handoff más reciente `pending`, `to_channel='whatsapp'` y `scheduled_for <= now()`.
3. Ejecutar `claim_handoff(id)` antes de responder.
4. Construir el mensaje desde payload validado, sin permitir que el LLM invente montos, fechas, comprobantes u ofertas.
5. Abrir o vincular una conversación WhatsApp con `parent_conversation_id` apuntando a la llamada de voz.
6. Registrar los mensajes entrante y saliente con `log_message`.
7. Responder mediante Meta Cloud API dentro de la ventana abierta por el cliente.
8. Ejecutar `complete_handoff(id, conversationId, 'completed')` solo después de una respuesta exitosa de Meta.
9. En error, marcar `failed`, registrar el error sin secretos y permitir correo como fallback.
10. Evitar duplicados ante webhooks repetidos o dos procesos concurrentes.
11. Si no existe handoff pendiente, continuar con el chatbot entrante normal.

No implementar polling que envíe texto libre proactivamente: sin plantilla Meta lo rechazará. Dejar soporte opcional y desacoplado para una plantilla futura:

```env
META_HANDOFF_TEMPLATE_NAME=
META_HANDOFF_TEMPLATE_LANG=es
```

Si estas variables no existen, operar completamente en modo **inbound activation**: esperar `CONTINUAR` y responder. No simular que un texto libre fue enviado si Meta lo rechaza. En pruebas, mockear Meta Graph API; nunca enviar mensajes reales.

### 5. Contenido determinista por acción

Crear builders separados y testeables:

- `SEND_PAYMENT_LINK`: saludo breve + resumen validado + `receipt_code` + `payment_url`.
- `SEND_COMMITMENT_SUMMARY`: estado correcto (`registrado` vs `pendiente de aprobación`) + condiciones.
- `SEND_OFFER_DETAILS`: solamente opciones autorizadas en el snapshot; sin prometer aprobación.
- `FOLLOW_UP_MESSAGE`: resumen neutral y siguiente paso.
- `CALLBACK`: fecha y franja validadas.

No incluir saldo, crédito o detalles sensibles hasta que el diseño de verificación de identidad del canal lo autorice. Para la demo, preferir mensajes mínimos y enlaces tokenizados.

### 6. Correo como fallback, no duplicado

Modificar `finalize.ts` y el envío de confirmación para que:

- Si el cliente aceptó WhatsApp y el handoff se completó, no enviar además correo automáticamente.
- Si el handoff queda pendiente, esperar un tiempo razonable o dejar que el worker gestione el fallback.
- Si WhatsApp falla, no está configurado o no está autorizado, enviar correo si la política lo permite.
- Mantener el cierre idempotente ante reintentos del webhook de ElevenLabs.

### 7. Dashboard

Verificar que la web refleje sin cambios grandes:

- `whatsapp_handoff_offered`
- `handoff_created`
- `handoff_completed`
- `handoff_failed`
- Conversación hija WhatsApp enlazada a la llamada
- Link de pago y compromiso

Si hace falta, realizar cambios mínimos en `web-banco` para mostrar “WhatsApp programado / enviado / falló” en la conversación. No duplicar decisiones de negocio en React.

## Pruebas obligatorias

Agregar pruebas sin llamadas reales a ElevenLabs, Meta ni Resend.

### Base de datos

- Cliente con consentimiento puede crear handoff.
- Sin consentimiento se rechaza.
- Opt-out se rechaza.
- Grupo de control se rechaza.
- Handoff duplicado devuelve el existente o un resultado idempotente.
- Dos `claim_handoff` simultáneos: solo uno obtiene `ok=true`.
- Payment link solo se crea para acción/estado permitido.

### Agente

- Compromiso + aceptación de WhatsApp → `SEND_PAYMENT_LINK`.
- Solicitud pendiente de aprobación → `SEND_COMMITMENT_SUMMARY`, nunca payment link.
- Interés sin compromiso → `SEND_OFFER_DETAILS`.
- Rechazo de WhatsApp → no handoff y no segunda oferta.
- `DO_NOT_CONTACT`, fraude, disputa y persona equivocada → no handoff sensible.
- El agente no afirma “enviado” si la RPC falla.

### Bot

- Reclama, envía, registra y completa un handoff.
- Un `CONTINUAR` entrante activa el handoff pendiente del mismo teléfono.
- Sin mensaje entrante y sin plantilla no se intenta ningún envío proactivo.
- Error de Meta → estado `failed` y evento correspondiente.
- Reinicio del worker no duplica el envío.
- El mensaje usa exactamente monto, fecha y recibo del payload.
- Handoff ya procesado no vuelve a enviarse.

### Regresión

Al terminar deben pasar:

```bash
cd /Users/rafaelsandoval/dev/entropy-banco
npm run agent:build
npm run db:test

cd /Users/rafaelsandoval/dev/web-banco
pnpm lint
pnpm build
```

Mantener las 80 aserciones actuales y sumar las nuevas.

## Escenario de aceptación end-to-end

Usar llamada simulada para automatizar y una llamada real para ensayo manual:

1. Carlos recibe llamada preventiva.
2. Explica que puede pagar el viernes.
3. El agente valida la fecha y presenta condiciones.
4. Carlos confirma.
5. Se registra un compromiso con `receipt_code`.
6. Sin que Carlos lo pida, el agente pregunta si desea comprobante y link por WhatsApp.
7. Carlos acepta.
8. Se crea exactamente un handoff `SEND_PAYMENT_LINK`.
9. El agente indica que Carlos debe escribir `CONTINUAR` al WhatsApp del banco y cierra.
10. Carlos envía `CONTINUAR` desde su teléfono.
11. El bot identifica a Carlos, reclama el handoff y Meta acepta la respuesta.
12. El handoff pasa a `completed` y queda ligado a una conversación WhatsApp hija.
13. El dashboard muestra el evento y el mensaje.
14. El link abre `/pagar/[token]`.
15. El pago simulado marca el compromiso como cumplido y actualiza impacto.

## Definición de terminado

- El cliente no tiene que pedir WhatsApp: el agente lo sugiere en el momento correcto.
- No se envía nada sin consentimiento/política aplicable.
- Voz y WhatsApp quedan unidos mediante `parent_conversation_id` y `handoffs`.
- Existe trazabilidad completa desde oferta hasta entrega.
- No hay envíos duplicados.
- No hay confirmaciones sin Receipt.
- Correo funciona como fallback y no como duplicado.
- La demo funciona en modo simulado sin proveedores externos.
- La demo real funciona sin plantilla: el cliente abre la ventana enviando `CONTINUAR`.
- Una plantilla Meta futura puede habilitar el envío proactivo sin cambiar el contrato de handoffs.
- Builds, lint y pruebas pasan.

## Entrega esperada de Claude

Al finalizar, responder con:

1. Resumen del comportamiento implementado.
2. Archivos y migraciones modificados.
3. Decisiones de consentimiento y fallback.
4. Pruebas ejecutadas y resultados.
5. Variables de entorno nuevas.
6. Pasos exactos para probar la demo voz → WhatsApp.
7. Limitaciones restantes, especialmente la ventana de 24 horas y aprobación de plantillas de Meta.
