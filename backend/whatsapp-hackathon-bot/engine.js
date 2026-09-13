import {
  findCustomerByPhone,
  getActiveConversation,
  getRecentlyEndedConversation,
  startConversation,
  logMessage,
  evaluateTurn,
  endConversation,
  getPromptVersion,
  getRecentMessages,
  validateOffer,
  registerCommitment,
  createPaymentLink,
} from './supabase.js';
import { askScorecard, askComposer, extractOfferParams } from './gemini.js';

function formatTranscript(messages) {
  return messages.map((m) => `${m.role}: ${m.content}`).join('\n');
}

function formatOffers(offers) {
  if (!offers || offers.length === 0) return 'Ninguna opción disponible en este turno.';
  return offers
    .map((o, i) => `${i + 1}. ${o.name ?? o.code} — ${o.description ?? o.pitch ?? ''}`.trim())
    .join('\n');
}

function findCriteriaTexts(criteriaCatalog, keys) {
  const catalog = new Map((criteriaCatalog ?? []).map((c) => [c.key, c]));
  return (keys ?? [])
    .map((k) => catalog.get(k))
    .filter(Boolean)
    .map((c) => `- ${c.label}: ${c.description}`)
    .join('\n');
}

function findStage(contextSnapshot, stageKey) {
  const stages = contextSnapshot?.playbook?.stages ?? [];
  return stages.find((s) => s.key === stageKey);
}

// Devuelve null si el número no corresponde a ningún cliente de la demo.
export async function handleIncomingMessage(phone, text) {
  const customer = await findCustomerByPhone(phone);
  if (!customer?.customer_id) return null;

  let conversation = await getActiveConversation(customer.customer_id, 'whatsapp');
  let contextSnapshot;
  let currentStage;
  let justClosedOutcome = null;

  if (!conversation) {
    // Si su conversación anterior terminó hace poco (ej. quedó en
    // REAGENDADO tras acordar una hora de rellamada), este mensaje casi
    // siempre es una continuación/despedida breve ("gracias", "listo", "a
    // esa hora está bien") — no un cliente nuevo. Se abre igual una fila en
    // conversations para loguear el mensaje, pero se le avisa al composer
    // para que NO repita el guion de apertura/verificación de identidad.
    const recentlyEnded = await getRecentlyEndedConversation(customer.customer_id, 'whatsapp');
    if (recentlyEnded) justClosedOutcome = recentlyEnded.outcome ?? 'cerrada';

    const started = await startConversation(customer.customer_id, 'whatsapp', 'inbound');
    conversation = { id: started.conversation_id };
    contextSnapshot = started.context;
    currentStage = started.current_stage;
  } else {
    contextSnapshot = conversation.context_snapshot;
    currentStage = conversation.current_stage;
  }

  const inbound = await logMessage(conversation.id, 'customer', text);

  const stage = findStage(contextSnapshot, currentStage) ?? {};
  const criterios = findCriteriaTexts(contextSnapshot?.criteria_catalog, stage.criteria);
  const recentBefore = await getRecentMessages(conversation.id, 8);

  // Antes de evaluar el turno (evaluate_turn, que decide qué ofertas van
  // en ESTE turno) todavía no sabemos exactamente qué se le mostró al
  // cliente ahorita — pero sí sabemos el catálogo congelado al abrir la
  // conversación (contextSnapshot.offers), que es lo que normalmente se le
  // presenta. Se le pasa al supervisor con su código real y su posición,
  // para que si el cliente responde "opción 2" o "la de cambiar fecha"
  // pueda traducirlo al código correcto en vez de copiar el número tal cual.
  const offersCatalog = contextSnapshot?.offers ?? [];
  const ofertasConCodigo = offersCatalog.length
    ? offersCatalog.map((o, i) => `${i + 1}. ${o.code} — ${o.name}`).join('\n')
    : 'Ninguna.';

  const supervisorPrompt = await getPromptVersion('supervisor.scorecard');
  const scorecard = await askScorecard(supervisorPrompt.content, {
    etapa_nombre: stage.name ?? currentStage,
    etapa_objetivo: stage.objective ?? '',
    criterios,
    ofertas_con_codigo: ofertasConCodigo,
    transcripcion_reciente: formatTranscript(recentBefore),
  }, supervisorPrompt.output_schema);

  const evalResult = await evaluateTurn(conversation.id, scorecard, inbound.message_id);
  if (process.env.DEBUG_ENGINE) {
    console.log('[DEBUG] scorecard:', JSON.stringify(scorecard));
    console.log('[DEBUG] evalResult.stage:', JSON.stringify(evalResult?.stage));
    console.log('[DEBUG] evalResult.control_message:', evalResult?.control_message);
  }

  const composerPrompt = await getPromptVersion('composer.whatsapp');
  const customerInfo = contextSnapshot?.customer ?? {};
  const loanInfo = contextSnapshot?.loan ?? {};
  const riskInfo = contextSnapshot?.risk ?? {};
  const contextoCliente = [
    `Cliente: ${customerInfo.full_name ?? ''}`,
    loanInfo.id ? `Producto: ${loanInfo.product_name}. Cuota: ${loanInfo.amount_due_text} vence ${loanInfo.next_due_date_text}.` : 'Sin crédito activo con cuota pendiente.',
    riskInfo.band ? `Nivel de riesgo: ${riskInfo.band}.` : '',
  ].filter(Boolean).join('\n');

  // OJO: solo se le pasan ofertas al composer cuando la ETAPA REAL (decidida
  // por evaluate_turn, no por lo que "suene bien") las permite. Antes esto
  // caía siempre al listado completo del contexto inicial aunque la etapa
  // fuera APERTURA/CONTEXTO/DESCUBRIMIENTO, y el composer terminaba
  // inventando un menú de ofertas antes de tiempo.
  const offersForTurn = evalResult?.stage?.allows_offers
    ? ((evalResult.allowed_offers && evalResult.allowed_offers.length > 0) ? evalResult.allowed_offers : contextSnapshot?.offers)
    : [];

  // Aquí es donde de verdad se aplican los límites del banco (ej. máximo
  // 15 días de extensión). Antes de esto, el composer solo "narraba" lo que
  // el cliente pedía sin que nada verificara si cumplía la política —
  // podía "aceptar" mover una cuota de septiembre a diciembre sin ningún
  // control. Ahora, si el cliente ya mostró una señal de compromiso fuerte
  // sobre una oferta concreta, se extraen los parámetros reales (fechas
  // relativas → ISO) y se validan contra validate_offer ANTES de que el
  // composer confirme nada.
  const validationNote = await validateProposedOffer({
    scorecard,
    offersForTurn,
    contextSnapshot,
    conversationId: conversation.id,
    transcript: formatTranscript(recentBefore),
  });

  const recentAfter = await getRecentMessages(conversation.id, 8);

  const reopenNote = justClosedOutcome
    ? `\n[NOTA DEL SISTEMA — PRIORIDAD ALTA] Este mismo cliente terminó otra conversación con usted hace muy poco (resultado: ${justClosedOutcome}). Si su mensaje es solo una despedida, agradecimiento o continuación breve del tema anterior (ej. "gracias", "listo", "a esa hora está bien"), IGNORA la instrucción de presentarte o verificar identidad de nuevo — no reinicies el guion de apertura. Responde solo con calidez y brevedad, como si fuera la misma conversación.`
    : '';

  const reply = await askComposer(composerPrompt.content, {
    cliente_nombre: customerInfo.first_name ?? '',
    contexto_cliente: contextoCliente,
    control_message: (evalResult.control_message ?? '') + validationNote + reopenNote,
    ofertas: formatOffers(offersForTurn),
    historial: formatTranscript(recentAfter),
  });

  await logMessage(conversation.id, 'agent', reply);

  if (evalResult.is_terminal && evalResult.suggested_outcome) {
    await endConversation(conversation.id, evalResult.suggested_outcome);
  }

  // Selección interactiva: `allows_offers` está en true en 4 etapas
  // (PROPUESTA, OBJECIONES, COMPROMISO, CONFIRMACION), pero solo en
  // PROPUESTA/OBJECIONES el cliente está de verdad ELIGIENDO entre
  // ofertas — ahí sí tiene sentido la lista. En COMPROMISO ya eligió y
  // lo que se le pide es una fecha/monto concreto (texto libre); en
  // CONFIRMACION se le pide un sí/no sobre lo ya elegido (botones).
  const stageKey = evalResult?.stage?.key;
  const list = (stageKey === 'PROPUESTA' || stageKey === 'OBJECIONES')
    ? buildOfferList(evalResult, offersForTurn, contextSnapshot)
    : null;
  const buttons = stageKey === 'CONFIRMACION'
    ? [{ id: 'CONFIRMAR_SI', title: 'Sí, confirmar' }, { id: 'CONFIRMAR_NO', title: 'No, esperar' }]
    : null;

  return { text: reply, list, buttons };
}

// Solo dispara la validación real cuando el cliente ya mostró una señal de
// compromiso seria ("strong"/"explicit") sobre una oferta identificable —
// así no se gasta una llamada extra a Gemini en cada turno, solo cuando
// realmente hay algo concreto que verificar contra la política del banco.
// El supervisor a veces copia el NÚMERO de la lista ("3", "opción 2") en vez
// del código real de la oferta (ej. EXTENSION_15) — es un texto libre, no
// siempre acierta. Antes de descartar la propuesta por "código inválido",
// se intenta traducir esa posición numérica usando la MISMA lista que se le
// mostró al cliente en ese turno.
//
// IMPORTANTE: `offersForTurn` es la lista RECALCULADA por evaluate_turn para
// ESTE turno (puede reducirse si las reglas de negocio ya no la consideran
// prioritaria) — pero el cliente puede estar confirmando una oferta que se
// acordó turnos ANTES y que ya no aparece en esa lista corta. Por eso el
// código también se busca en el catálogo COMPLETO congelado al abrir la
// conversación (contextSnapshot.offers): si el código existe ahí, es una
// oferta real del banco y se deja seguir a validate_offer (que sí aplica
// las reglas de política/elegibilidad de verdad). Solo la resolución por
// POSICIÓN NUMÉRICA se limita a offersForTurn, porque el número solo tiene
// sentido relativo a lo que se le mostró al cliente en este turno.
function resolveOfferCode(rawCode, offersForTurn, fullCatalog) {
  if (!rawCode) return null;
  if ((offersForTurn ?? []).some((o) => o.code === rawCode)) return rawCode;
  if ((fullCatalog ?? []).some((o) => o.code === rawCode)) return rawCode;
  const asPosition = parseInt(rawCode, 10);
  if (!Number.isNaN(asPosition) && offersForTurn?.[asPosition - 1]) {
    return offersForTurn[asPosition - 1].code;
  }
  return null;
}

async function validateProposedOffer({ scorecard, offersForTurn, contextSnapshot, conversationId, transcript }) {
  const code = resolveOfferCode(scorecard?.offer_code, offersForTurn, contextSnapshot?.offers);
  if (process.env.DEBUG_ENGINE) {
    console.log('[DEBUG] raw offer_code from scorecard:', JSON.stringify(scorecard?.offer_code), '-> resolved:', code, 'commitment_signal:', scorecard?.commitment_signal, 'confirmation_given:', scorecard?.confirmation_given);
  }
  if (!code) return '';
  if (!['strong', 'explicit'].includes(scorecard?.commitment_signal)) return '';

  const fullOffer = (contextSnapshot?.offers ?? []).find((o) => o.code === code);
  if (!fullOffer?.offer_type) return '';

  const todayIso = new Date().toISOString().slice(0, 10);
  const dueDateIso = contextSnapshot?.loan?.next_due_date ?? '';

  const params = await extractOfferParams({
    offerType: fullOffer.offer_type,
    transcript,
    todayIso,
    dueDateIso,
  });

  const validation = await validateOffer(conversationId, code, params);
  if (process.env.DEBUG_ENGINE) {
    console.log('[DEBUG] resolved offer code:', code, 'params:', JSON.stringify(params), 'validation:', JSON.stringify(validation));
  }

  if (!validation.valid) {
    return `\n[VALIDACIÓN DEL SISTEMA — NO IGNORAR] La propuesta del cliente para "${code}" NO cumple la política del banco: ${(validation.errors ?? []).join(', ')}. ${validation.instruction ?? ''} Explica el límite real (no inventes uno) y ofrece la alternativa más cercana que sí esté permitida.`;
  }

  let note = `\n[VALIDACIÓN DEL SISTEMA — NO IGNORAR] La propuesta SÍ cumple la política. Términos exactos a comunicar (cópialos tal cual, no los cambies): "${validation.terms_text}". ${validation.instruction ?? ''}`;

  if (scorecard?.confirmation_given === 'yes') {
    const commitment = await registerCommitment(conversationId, code, params, true);
    if (commitment?.ok) {
      note += ` Quedó registrado de verdad con el código ${commitment.receipt_code} — puedes confirmárselo al cliente con ese código exacto.`;

      // Simulado (no cobra nada real), pero la URL sí existe de verdad en
      // la tabla payment_links — antes el composer decía "le mando el link"
      // sin generar ninguno.
      if (fullOffer.generates_payment_link && !commitment.idempotent) {
        try {
          const link = await createPaymentLink(conversationId, commitment.commitment_id);
          note += ` Además, ya se generó el link de pago simulado: ${link.url} (vence ${link.expires_at}). Cuando le ofrezcas mandarle el link, usa esta URL exacta — nunca inventes una distinta.`;
        } catch (err) {
          console.warn('No se pudo generar el link de pago:', err?.message ?? err);
        }
      }
    } else {
      note += ` OJO: intentó confirmarse pero el registro falló (${(commitment?.errors ?? []).join(', ')}) — no digas que quedó registrado, explica que hay que intentarlo de nuevo.`;
    }
  }

  return note;
}

// cta_label (título corto para el botón) solo viene en el snapshot inicial
// del contexto, no en el recorte que devuelve evaluate_turn — por eso se
// arma un mapa code -> cta_label para usarlo aunque offersForTurn venga
// del RPC.
function buildOfferList(evalResult, offersForTurn, contextSnapshot) {
  const allowsOffers = evalResult?.stage?.allows_offers === true;
  if (!allowsOffers || !Array.isArray(offersForTurn) || offersForTurn.length === 0) return null;

  const ctaByCode = new Map((contextSnapshot?.offers ?? []).map((o) => [o.code, o.cta_label]));

  return {
    rows: offersForTurn.slice(0, 10).map((o) => ({
      id: o.code,
      title: ctaByCode.get(o.code) || o.name || o.code,
      description: o.name ?? '',
    })),
  };
}
