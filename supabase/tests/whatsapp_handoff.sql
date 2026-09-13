-- @@ reset
select (reset_demo())->'ok';
-- @@ tabla
create temp table _t (n serial, paso text, ok boolean, detalle text);
-- @@ handoff voz → whatsapp
do $$
declare
  carlos  uuid := '00000000-0000-4000-8000-000000000001';   -- contactable, consentimiento normal
  maria   uuid := '00000000-0000-4000-8000-000000000002';   -- contactable, sin compromiso previo (para no chocar con el de Carlos)
  control uuid := '00000000-0000-4000-8000-000000000009';   -- grupo de control
  optout  uuid := '00000000-0000-4000-8000-000000000011';   -- pidió no ser contactado
  r jsonb; conv uuid; conv2 uuid; hid uuid;
begin
  perform set_demo_contact('DEMO-001', '+50370000001');
  perform set_demo_contact('DEMO-002', '+50370000002');
  perform set_demo_contact('DEMO-009', '+50370000009');
  perform set_demo_contact('DEMO-011', '+50370000011');   -- limpia opted_out_at: se restaura después de abrir la conversación

  -- 1) cliente con consentimiento puede crear handoff (con compromiso ya registrado)
  r := start_conversation(carlos, 'voice', 'outbound', 'wa-test-1');
  conv := (r->>'conversation_id')::uuid;
  perform validate_offer(conv, 'PAGO_TOTAL', '{}');
  r := register_commitment(conv, 'PAGO_TOTAL', '{}', true);
  insert into _t(paso,ok,detalle) values ('compromiso registrado antes del handoff', (r->>'ok')::boolean, r->>'receipt_code');

  r := create_handoff(conv, 'whatsapp', 'SEND_PAYMENT_LINK');
  insert into _t(paso,ok,detalle) values ('cliente con consentimiento puede crear handoff', (r->>'ok')::boolean and r->'payload'->>'payment_token' is not null, r::text);
  hid := (r->>'handoff_id')::uuid;

  -- 2) idempotente: mismo to_channel+action en la misma conversación no duplica
  r := create_handoff(conv, 'whatsapp', 'SEND_PAYMENT_LINK');
  insert into _t(paso,ok,detalle) values ('handoff duplicado devuelve el existente (idempotente)', (r->>'idempotent')::boolean and (r->>'handoff_id')::uuid = hid, r->>'handoff_id');
  insert into _t(paso,ok,detalle) values ('no se duplicó la fila en handoffs', (select count(*) from handoffs where from_conversation_id = conv and action = 'SEND_PAYMENT_LINK') = 1, null);

  -- 3) sin consentimiento de WhatsApp se rechaza (sin lanzar excepción, con motivo explícito)
  update customers set consent_whatsapp = false where id = carlos;
  r := create_handoff(conv, 'whatsapp', 'SEND_COMMITMENT_SUMMARY');
  insert into _t(paso,ok,detalle) values ('sin consentimiento de whatsapp se rechaza', not (r->>'ok')::boolean and r->>'error' = 'SIN_CONSENTIMIENTO_PARA_CANAL', r::text);
  insert into _t(paso,ok,detalle) values ('rechazo queda auditado (whatsapp_handoff_declined)',
    exists (select 1 from conversation_events where conversation_id = conv and event_type = 'whatsapp_handoff_declined' and payload->>'reason' = 'SIN_CONSENTIMIENTO_PARA_CANAL'), null);
  update customers set consent_whatsapp = true where id = carlos;

  -- 4) opt-out se rechaza: la conversación abrió antes de pedir "no me llamen"; create_handoff revisa el estado ACTUAL, no el de apertura
  r := start_conversation(optout, 'voice', 'outbound', 'wa-test-optout');
  conv2 := (r->>'conversation_id')::uuid;
  update customers set opted_out_at = now(), opt_out_reason = 'Pidió no ser contactado' where id = optout;
  r := create_handoff(conv2, 'whatsapp', 'FOLLOW_UP_MESSAGE');
  insert into _t(paso,ok,detalle) values ('opt-out se rechaza', not (r->>'ok')::boolean and r->>'error' = 'CLIENTE_PIDIO_NO_SER_CONTACTADO', r::text);

  -- 5) grupo de control se rechaza
  r := start_conversation(control, 'voice', 'outbound', 'wa-test-control', p_force => true);
  conv2 := (r->>'conversation_id')::uuid;
  r := create_handoff(conv2, 'whatsapp', 'FOLLOW_UP_MESSAGE');
  insert into _t(paso,ok,detalle) values ('grupo de control se rechaza', not (r->>'ok')::boolean and r->>'error' = 'GRUPO_DE_CONTROL', r::text);

  -- 6) payment link solo se crea para acción/estado permitido: sin compromiso registrado
  r := start_conversation(maria, 'voice', 'outbound', 'wa-test-nocommit');
  conv2 := (r->>'conversation_id')::uuid;
  r := create_handoff(conv2, 'whatsapp', 'SEND_PAYMENT_LINK');
  insert into _t(paso,ok,detalle) values ('sin compromiso no se puede pedir link de pago', not (r->>'ok')::boolean and r->>'error' = 'SIN_COMPROMISO_REGISTRADO', r::text);

  -- 7) SEND_OFFER_DETAILS solo usa las ofertas congeladas al iniciar (allowed_offers), no lo que el modelo invente
  r := create_handoff(conv2, 'whatsapp', 'SEND_OFFER_DETAILS');
  insert into _t(paso,ok,detalle) values ('detalle de ofertas sale de allowed_offers del snapshot',
    (r->'payload'->'offers') = (select allowed_offers from conversations where id = conv2), r->'payload'->'offers');

  -- 8) dos claim_handoff no procesan el mismo handoff dos veces
  r := claim_handoff(hid);
  insert into _t(paso,ok,detalle) values ('bot toma el handoff', (r->>'ok')::boolean, r->'handoff'->>'status');
  r := claim_handoff(hid);
  insert into _t(paso,ok,detalle) values ('un segundo claim no lo vuelve a tomar', not (r->>'ok')::boolean, r->>'error');

  -- 9) complete_handoff registra evento y no se puede completar dos veces con éxito silencioso engañoso
  r := complete_handoff(hid, conv2, 'completed');
  insert into _t(paso,ok,detalle) values ('completar handoff queda ok', (r->>'ok')::boolean, null);
  insert into _t(paso,ok,detalle) values ('handoff_completed queda auditado en la llamada de origen',
    exists (select 1 from conversation_events where conversation_id = conv and event_type = 'handoff_completed' and payload->>'handoff_id' = hid::text), null);

  -- 10) handoff fallido queda como failed, auditado, sin fingir éxito
  r := start_conversation(maria, 'voice', 'outbound', 'wa-test-fail');
  conv2 := (r->>'conversation_id')::uuid;
  perform validate_offer(conv2, 'PAGO_TOTAL', '{}');
  r := register_commitment(conv2, 'PAGO_TOTAL', '{}', true);
  r := create_handoff(conv2, 'whatsapp', 'SEND_PAYMENT_LINK');
  r := complete_handoff((r->>'handoff_id')::uuid, null, 'failed', 'META_ENVIO_RECHAZADO');
  insert into _t(paso,ok,detalle) values ('handoff fallido queda como failed y auditado',
    exists (select 1 from conversation_events where conversation_id = conv2 and event_type = 'handoff_failed' and payload->>'error' = 'META_ENVIO_RECHAZADO'), null);
end $$;
-- @@ RESULTADOS
select n, case when ok then '✅' else '❌' end as r, paso, left(detalle, 140) detalle from _t order by n;
