import {
  findCustomerByPhone,
  getActiveConversation,
  startConversation,
  logMessage,
  evaluateTurn,
  endConversation,
  getPromptVersion,
  getRecentMessages,
} from './supabase.js';
import { askScorecard, askComposer } from './gemini.js';

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

  if (!conversation) {
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

  const supervisorPrompt = await getPromptVersion('supervisor.scorecard');
  const scorecard = await askScorecard(supervisorPrompt.content, {
    etapa_nombre: stage.name ?? currentStage,
    etapa_objetivo: stage.objective ?? '',
    criterios,
    transcripcion_reciente: formatTranscript(recentBefore),
  }, supervisorPrompt.output_schema);

  const evalResult = await evaluateTurn(conversation.id, scorecard, inbound.message_id);

  const composerPrompt = await getPromptVersion('composer.whatsapp');
  const customerInfo = contextSnapshot?.customer ?? {};
  const loanInfo = contextSnapshot?.loan ?? {};
  const riskInfo = contextSnapshot?.risk ?? {};
  const contextoCliente = [
    `Cliente: ${customerInfo.full_name ?? ''}`,
    loanInfo.id ? `Producto: ${loanInfo.product_name}. Cuota: ${loanInfo.amount_due_text} vence ${loanInfo.next_due_date_text}.` : 'Sin crédito activo con cuota pendiente.',
    riskInfo.band ? `Nivel de riesgo: ${riskInfo.band}.` : '',
  ].filter(Boolean).join('\n');

  const offersForTurn = (evalResult.allowed_offers && evalResult.allowed_offers.length > 0)
    ? evalResult.allowed_offers
    : contextSnapshot?.offers;

  const recentAfter = await getRecentMessages(conversation.id, 8);

  const reply = await askComposer(composerPrompt.content, {
    cliente_nombre: customerInfo.first_name ?? '',
    contexto_cliente: contextoCliente,
    control_message: evalResult.control_message ?? '',
    ofertas: formatOffers(offersForTurn),
    historial: formatTranscript(recentAfter),
  });

  await logMessage(conversation.id, 'agent', reply);

  if (evalResult.is_terminal && evalResult.suggested_outcome) {
    await endConversation(conversation.id, evalResult.suggested_outcome);
  }

  return reply;
}
