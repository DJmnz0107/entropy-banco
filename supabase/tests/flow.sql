-- @@ reset
select (reset_demo())->'ok';
-- @@ tabla
create temp table _t (n serial, paso text, ok boolean, detalle text);
-- @@ flujo
do $$
declare
  carlos uuid := '00000000-0000-4000-8000-000000000001';
  elena  uuid := '00000000-0000-4000-8000-000000000012';
  r jsonb; conv uuid; msg uuid; e text; tok text; conv2 uuid; due date;
  procedure_ok boolean;
begin
  -- Guardas antes de habilitar
  begin perform start_conversation(carlos, 'voice'); insert into _t(paso,ok,detalle) values ('bloquea número no habilitado', false, 'no lanzó error');
  exception when others then insert into _t(paso,ok,detalle) values ('bloquea número no habilitado', sqlerrm like 'CONTACTO_NO_HABILITADO%', left(sqlerrm,80)); end;

  perform set_demo_contact('DEMO-001', '+50370000001');
  perform set_demo_contact('DEMO-008', '+50370000008');
  perform set_demo_contact('DEMO-009', '+50370000009');
  perform set_demo_contact('DEMO-012', '+50370000012');

  begin perform start_conversation('00000000-0000-4000-8000-000000000008', 'whatsapp'); insert into _t(paso,ok,detalle) values ('bloquea disputa abierta', false, 'no lanzó');
  exception when others then insert into _t(paso,ok,detalle) values ('bloquea disputa abierta', sqlerrm like 'CONTACTO_BLOQUEADO_POR_REGLA%', left(sqlerrm,80)); end;
  begin perform start_conversation('00000000-0000-4000-8000-000000000009', 'voice'); insert into _t(paso,ok,detalle) values ('no contacta grupo de control', false, 'no lanzó');
  exception when others then insert into _t(paso,ok,detalle) values ('no contacta grupo de control', sqlerrm like 'GRUPO_DE_CONTROL%', left(sqlerrm,80)); end;

  -- ═══ Llamada de Carlos ═══
  r := start_conversation(carlos, 'voice', 'outbound', 'call-test-1', null, null, 'EXP-VOZ-02');
  conv := (r->>'conversation_id')::uuid;
  insert into _t(paso,ok,detalle) values ('start_conversation', r->>'current_stage' = 'APERTURA',
    format('etapa=%s voz=%s ofertas=%s', r->>'current_stage', r->'models'->'voice_realtime'->>'key',
           (select string_agg(o->>'code', ',') from jsonb_array_elements(r->'context'->'offers') o)));
  insert into _t(paso,ok,detalle) values ('modelo trae VAD e interrupciones', (r->'models'->'voice_realtime'->'vad_config') ? 'silence_duration_ms'
    and (r->'models'->'voice_realtime'->'interruption_config') ? 'backchannel_phrases', r->'models'->'voice_realtime'->'vad_config'->>'start_of_speech_sensitivity');

  perform log_message(conv, 'agent', 'Buenos días, Carlos. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con Carlos Martínez Aguilar?', '{"latency_ms":820}');
  perform log_message(conv, 'customer', 'Sí, soy yo.');
  r := evaluate_turn(conv, '{"identity_confirmed":"yes","sentiment":"NEUTRAL","confidence":0.95}');
  insert into _t(paso,ok,detalle) values ('identidad → CONTEXTO', r->>'to_stage' = 'CONTEXTO', (r->>'decision') || ' · ' || (r->'rule'->>'label'));

  perform log_message(conv, 'customer', 'Mire, este mes ando complicado.');
  r := evaluate_turn(conv, '{"intent":"FINANCIAL_DIFFICULTY","payment_capacity":"partial","sentiment":"CONCERNED","resistance":0.2,"confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('dificultad → DESCUBRIMIENTO', r->>'to_stage' = 'DESCUBRIMIENTO', r->'rule'->>'label');

  r := evaluate_turn(conv, '{"payment_capacity":"partial","difficulty_reason":"income_delay","sentiment":"CONCERNED","confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('situación entendida → PROPUESTA con ≤3 ofertas', r->>'to_stage' = 'PROPUESTA' and jsonb_array_length(r->'allowed_offers') <= 3,
    (select string_agg(o->>'code', ',') from jsonb_array_elements(r->'allowed_offers') o));
  insert into _t(paso,ok,detalle) values ('mensaje [CONTROL] generado', r->>'control_message' like '[CONTROL] Etapa: Presentar opciones%', left(r->>'control_message', 120));

  -- Ofertas fuera de política
  r := validate_offer(conv, 'PLAN_3_CUOTAS', '{"installments":6}');
  insert into _t(paso,ok,detalle) values ('rechaza 6 cuotas en plan de 2-3', not (r->>'valid')::boolean, r->>'errors');
  select due_date into due from installments i join loans l on l.id=i.loan_id where l.customer_id=carlos and i.status='pending' order by due_date limit 1;
  r := validate_offer(conv, 'EXTENSION_15', jsonb_build_object('new_date', due + 40));
  insert into _t(paso,ok,detalle) values ('rechaza extensión de 40 días', not (r->>'valid')::boolean, r->>'errors');
  r := validate_offer(conv, 'CONDONACION_RECARGO', '{}');
  insert into _t(paso,ok,detalle) values ('rechaza oferta no permitida por reglas', r->'errors' ? 'OFERTA_NO_PERMITIDA_PARA_ESTE_CLIENTE', r->>'errors');

  -- Oferta válida + interrupción durante condiciones
  r := validate_offer(conv, 'PLAN_3_CUOTAS', '{"installments":3}');
  insert into _t(paso,ok,detalle) values ('valida plan 3 cuotas con términos', (r->>'valid')::boolean, r->>'terms_text');
  msg := ((log_message(conv, 'agent', r->>'terms_text', '{"latency_ms":1100,"audio_ms":7400}'))->>'message_id')::uuid;
  r := log_interruption(conv, 'real', msg, 'Pago inicial de $38', 1800, 7400, 'Espere, ¿cuánto dijo?');
  insert into _t(paso,ok,detalle) values ('interrupción invalida términos', (r->>'must_restate_terms')::boolean, r->>'control_message');
  r := register_commitment(conv, 'PLAN_3_CUOTAS', '{"installments":3}', true);
  insert into _t(paso,ok,detalle) values ('BD RECHAZA compromiso con términos interrumpidos', r->'errors' ? 'CONDICIONES_INTERRUMPIDAS', r->>'instruction');

  r := log_interruption(conv, 'backchannel', null, null, null, null, 'ajá');
  insert into _t(paso,ok,detalle) values ('asentimiento no invalida nada', not (r->>'must_restate_terms')::boolean, r->>'control_message');

  r := validate_offer(conv, 'PLAN_3_CUOTAS', '{"installments":3}');
  insert into _t(paso,ok,detalle) values ('repetir términos limpia la interrupción',
    (select not ('PLAN_3_CUOTAS' = any(terms_interrupted)) from conversations where id = conv), 'terms_interrupted vacío');

  r := evaluate_turn(conv, '{"offer_interest":"accepted","offer_code":"PLAN_3_CUOTAS","commitment_signal":"strong","engagement":0.8,"sentiment":"NEUTRAL","confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('acepta → COMPROMISO, ritmo rápido', r->>'to_stage' = 'COMPROMISO' and r->>'pace' = 'fast', (r->>'pace'));
  r := evaluate_turn(conv, '{"commitment_signal":"explicit","extracted_date_text":"el viernes","confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('compromiso explícito → CONFIRMACION', r->>'to_stage' = 'CONFIRMACION', r->'rule'->>'label');

  r := evaluate_turn(conv, '{"confirmation_given":"unknown","is_backchannel":"yes","confidence":0.8}');
  insert into _t(paso,ok,detalle) values ('"unknown" NO se toma como rechazo (se queda)', r->>'decision' = 'stay' and r->>'to_stage' = 'CONFIRMACION', r->>'decision');

  r := register_commitment(conv, 'PLAN_3_CUOTAS', '{"installments":3}', false);
  insert into _t(paso,ok,detalle) values ('exige sí explícito', r->'errors' ? 'CONFIRMACION_EXPLICITA_REQUERIDA', r->>'errors');
  r := register_commitment(conv, 'PLAN_3_CUOTAS', '{"installments":3}', true);
  insert into _t(paso,ok,detalle) values ('registra compromiso con recibo', (r->>'ok')::boolean and r->>'receipt_code' like 'CMP-%', (r->>'receipt_code') || ' · ' || (r->>'summary'));
  r := register_commitment(conv, 'PLAN_3_CUOTAS', '{"installments":3}', true);
  insert into _t(paso,ok,detalle) values ('idempotente si el modelo llama 2 veces', (r->>'idempotent')::boolean, r->>'receipt_code');

  r := evaluate_turn(conv, '{"confirmation_given":"yes","sentiment":"POSITIVE","confidence":0.95}');
  insert into _t(paso,ok,detalle) values ('registrado → SIGUIENTE_PASO', r->>'to_stage' = 'SIGUIENTE_PASO', r->'rule'->>'label');

  r := create_handoff(conv, 'whatsapp', 'SEND_PAYMENT_LINK');
  tok := r->'payload'->>'payment_token';
  insert into _t(paso,ok,detalle) values ('handoff a WhatsApp con link', tok is not null, r->'payload'->>'payment_url');

  r := evaluate_turn(conv, '{"accepts_whatsapp_followup":"yes","sentiment":"POSITIVE","confidence":0.95}');
  insert into _t(paso,ok,detalle) values ('→ CIERRE (terminal)', r->>'decision' = 'end' and (r->>'is_terminal')::boolean, r->>'suggested_outcome');

  perform record_model_usage(conv, 'voice.gemini-3.1-flash-live', '{"audio_in_seconds":150,"audio_out_seconds":70}');
  perform record_model_usage(conv, 'supervisor.gemini-2.5-flash-lite', '{"text_in_tokens":9000,"text_out_tokens":1100}');
  r := end_conversation(conv, 'PAYMENT_PLAN_AGREED', 'Plan de 3 pagos acordado.');
  insert into _t(paso,ok,detalle) values ('cierra y recalcula riesgo', (r->>'risk_after')::int < (r->>'risk_before')::int,
    format('riesgo %s → %s · costo $%s', r->>'risk_before', r->>'risk_after', (select cost_usd from conversations where id = conv)));

  r := claim_handoff((select id from handoffs where from_conversation_id = conv));
  insert into _t(paso,ok,detalle) values ('bot WhatsApp toma el handoff', (r->>'ok')::boolean, r->'handoff'->>'context_summary');
  r := claim_handoff((select id from handoffs where from_conversation_id = conv));
  insert into _t(paso,ok,detalle) values ('handoff no se toma 2 veces', not (r->>'ok')::boolean, r->>'error');

  r := get_payment_link(tok);
  insert into _t(paso,ok,detalle) values ('página pública del link', (r->>'found')::boolean, (r->>'first_name') || ' ' || (r->>'amount_text'));
  r := simulate_payment(tok);
  insert into _t(paso,ok,detalle) values ('pago simulado', (r->>'ok')::boolean, r->>'receipt');
  insert into _t(paso,ok,detalle) values ('compromiso queda CUMPLIDO',
    (select status from commitments where conversation_id = conv) = 'kept', (select status from commitments where conversation_id = conv));

  -- ═══ Elena: doble negativa (control global) ═══
  r := start_conversation(elena, 'whatsapp');
  conv2 := (r->>'conversation_id')::uuid;
  perform evaluate_turn(conv2, '{"identity_confirmed":"yes","confidence":0.9}');
  r := evaluate_turn(conv2, '{"explicit_refusal":"yes","intent":"REFUSES","sentiment":"FRUSTRATED","resistance":0.8,"confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('1ª negativa → OBJECIONES, ritmo lento', r->>'to_stage' = 'OBJECIONES' and r->>'pace' = 'slow', r->'rule'->>'label');
  r := evaluate_turn(conv2, '{"explicit_refusal":"yes","sentiment":"NEUTRAL","confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('2ª negativa → NEGATIVA_RESPETADA', r->>'to_stage' = 'NEGATIVA_RESPETADA' and r->>'decision' = 'end', r->'rule'->>'label');
  perform end_conversation(conv2, 'EXPLICIT_REFUSAL');

  -- pide humano → escalación automática
  r := start_conversation(elena, 'whatsapp', 'inbound');
  conv2 := (r->>'conversation_id')::uuid;
  r := evaluate_turn(conv2, '{"requests_human":"yes","sentiment":"NEUTRAL","confidence":0.9}');
  insert into _t(paso,ok,detalle) values ('pide humano → escalación creada', r->>'decision' = 'escalate' and r->>'escalation_id' is not null, r->'rule'->>'label');

  -- no me vuelvan a llamar
  r := start_conversation(elena, 'whatsapp', 'inbound');
  conv2 := (r->>'conversation_id')::uuid;
  r := evaluate_turn(conv2, '{"do_not_contact_request":"yes","sentiment":"FRUSTRATED","confidence":0.95}');
  insert into _t(paso,ok,detalle) values ('opt-out registrado en cliente', (select opted_out_at is not null from customers where id = elena), r->>'to_stage');

  -- silencio
  r := log_silence(conv2); r := log_silence(conv2); r := log_silence(conv2);
  insert into _t(paso,ok,detalle) values ('3 silencios → cerrar + sugerir WhatsApp', r->>'action' = 'end', r->>'suggested_outcome');

  -- resultado inválido
  begin perform end_conversation(conv2, 'INVENTADO');
    insert into _t(paso,ok,detalle) values ('rechaza outcome inventado', false, 'no lanzó');
  exception when others then insert into _t(paso,ok,detalle) values ('rechaza outcome inventado', sqlerrm like 'RESULTADO_INVALIDO%', left(sqlerrm, 60)); end;
end $$;
-- @@ RESULTADOS
select n, case when ok then '✅' else '❌' end as r, paso, left(detalle, 110) detalle from _t order by n;
-- @@ vistas en vivo
select channel, customer_code, current_stage, turn_count, last_rule from v_live_conversations;
