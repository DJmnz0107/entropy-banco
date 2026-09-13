-- @@ reset
select (reset_demo())->'prevention_run' as corrida;
-- @@ tabla
create temp table _t (n serial, paso text, ok boolean, detalle text);
-- @@ NBI personajes
select c.customer_code, n->>'grade' g, n->>'ssf_category' ssf, (n->>'risk_score') score, n->>'action' accion, n->>'channel' canal,
       left(n->>'why_channel', 70) por_que_canal, left(coalesce(n->>'blocked_reason', n->'why'->>0), 60) por_que,
       n->'education'->>'slug' video, jsonb_array_length(n->'plan') pasos, n->>'expected_avoided_amount' evitado
  from customers c cross join lateral (select next_best_intervention(c.id) n) x
 where c.is_demo_persona order by 1;
-- @@ flujo
do $$
declare
  carlos uuid := '00000000-0000-4000-8000-000000000001';
  r jsonb; run uuid; conv uuid; iv uuid; n int; s text;
begin
  r := next_best_intervention(carlos);
  insert into _t(paso,ok,detalle) values ('Carlos → llamada', r->>'action' in ('CALL_NOW','CALL_ALTERNATIVE_DATE') and r->>'channel'='voice', (r->>'action')||' · '||(r->>'why_channel'));
  insert into _t(paso,ok,detalle) values ('Carlos grado D y categoría SSF A1', r->>'grade'='D' and r->>'ssf_category'='A1', (r->>'grade')||'/'||(r->>'ssf_category'));
  insert into _t(paso,ok,detalle) values ('explica por qué', jsonb_array_length(r->'why') >= 3, r->>'why');
  r := next_best_intervention('00000000-0000-4000-8000-000000000008');
  insert into _t(paso,ok,detalle) values ('Rosa bloqueada (disputa)', r->>'action'='BLOCKED', r->>'blocked_reason');
  r := next_best_intervention('00000000-0000-4000-8000-000000000009');
  insert into _t(paso,ok,detalle) values ('Miguel grupo de control → no contactar', r->>'action'='MONITOR', r->>'blocked_reason');
  r := next_best_intervention('00000000-0000-4000-8000-000000000002');
  insert into _t(paso,ok,detalle) values ('María recibe video agro', r->'education'->>'slug'='agro-cosecha', r->'education'->>'title');
  insert into _t(paso,ok,detalle) values ('María grado C → llamada (política C–E)', r->>'channel'='voice', (r->>'action')||' · '||(r->>'why_channel'));
  r := next_best_intervention('00000000-0000-4000-8000-000000000003');
  insert into _t(paso,ok,detalle) values ('José grado A → solo correo', r->>'action'='EMAIL_REMINDER' and r->>'channel'='email', r->>'why_channel');
  r := next_best_intervention('00000000-0000-4000-8000-000000000001');
  insert into _t(paso,ok,detalle) values ('plan de llamada incluye correo si no contesta',
    exists (select 1 from jsonb_array_elements(r->'plan') x where x->>'type'='EMAIL'), (select string_agg(x->>'type', '→') from jsonb_array_elements(r->'plan') x));

  r := run_prevention('{"grades":["C","D","E"],"max_days_to_due":10}', 'test');
  run := (r->>'run_id')::uuid;
  insert into _t(paso,ok,detalle) values ('corrida prioriza', (r->>'requiring_intervention')::int > 0, r::text);
  insert into _t(paso,ok,detalle) values ('corrida excluye grado A/B', not exists (select 1 from interventions where prevention_run_id=run and grade in ('A','B')), r->>'by_grade');
  select count(*) into n from intervention_steps s join interventions i on i.id=s.intervention_id where i.prevention_run_id=run;
  insert into _t(paso,ok,detalle) values ('plan por pasos creado', n > 0, n || ' pasos');
  insert into _t(paso,ok,detalle) values ('corrida A–E: A–B van a correo',
    not exists (select 1 from interventions i where i.prevention_run_id = (run_prevention('{"grades":["A","B","C","D","E"],"max_days_to_due":10}','test')->>'run_id')::uuid
                 and i.status='scheduled' and ((i.grade in ('A','B') and i.recommended_channel <> 'email') or (i.grade in ('C','D','E') and i.recommended_channel not in ('voice','email')))),
    (select by_action::text from prevention_runs order by created_at desc limit 1));
  run := (select id from prevention_runs order by created_at desc limit 1);
  r := get_prevention_run(run, 'email');
  insert into _t(paso,ok,detalle) values ('lista de correos trae email y fecha', jsonb_array_length(r->'interventions') > 0
    and (r->'interventions'->0) ? 'email' and r->'interventions'->0->>'due_date_text' is not null, r->'interventions'->0->>'due_date_text');
  -- simulación: sin contact_enabled funciona; bloqueados siguen bloqueados; correo real exige contacto habilitado
  r := start_simulated_conversation('00000000-0000-4000-8000-000000000004', 'voice');
  insert into _t(paso,ok,detalle) values ('llamada simulada sin número habilitado', (r->>'simulated')::boolean
    and (select is_synthetic from conversations where id = (r->>'conversation_id')::uuid), r->>'conversation_id');
  perform end_conversation((r->>'conversation_id')::uuid, 'NO_ANSWER');
  begin perform start_simulated_conversation('00000000-0000-4000-8000-000000000008', 'voice');
    insert into _t(paso,ok,detalle) values ('simulación respeta bloqueo por regla', false, 'no lanzó');
  exception when others then insert into _t(paso,ok,detalle) values ('simulación respeta bloqueo por regla', sqlerrm like 'CONTACTO_BLOQUEADO%', left(sqlerrm,60)); end;
  begin perform start_conversation('00000000-0000-4000-8000-000000000003', 'email');
    insert into _t(paso,ok,detalle) values ('correo real exige contacto habilitado', false, 'no lanzó');
  exception when others then insert into _t(paso,ok,detalle) values ('correo real exige contacto habilitado', sqlerrm like 'CONTACTO_NO_HABILITADO%', left(sqlerrm,60)); end;
  r := start_simulated_conversation('00000000-0000-4000-8000-000000000003', 'email');
  perform log_message((r->>'conversation_id')::uuid, 'agent', 'Asunto: Tu cuota vence pronto');
  r := end_conversation((r->>'conversation_id')::uuid, 'MESSAGE_SENT');
  insert into _t(paso,ok,detalle) values ('correo cierra con MESSAGE_SENT', (r->>'ok')::boolean, r->>'outcome_label');
  run := (select id from prevention_runs where created_by='test' order by created_at desc limit 1);
  r := get_prevention_run(run, 'voice');
  insert into _t(paso,ok,detalle) values ('lista de despacho de voz incluye a Carlos',
    exists (select 1 from jsonb_array_elements(r->'interventions') x where x->>'customer_code'='DEMO-001'),
    jsonb_array_length(r->'interventions') || ' llamadas');

  -- el plan avanza solo con eventos
  select id into iv from interventions where prevention_run_id=run and customer_id=carlos;
  perform set_demo_contact('DEMO-001', '+50370000001');
  r := start_conversation(carlos, 'voice', 'outbound', 'el-test', null, iv);
  conv := (r->>'conversation_id')::uuid;
  select status into s from intervention_steps where intervention_id=iv and step_type='CALL';
  insert into _t(paso,ok,detalle) values ('paso CALL en curso al iniciar', s='in_progress', s);
  perform validate_offer(conv, 'PAGO_PARCIAL_50', '{}');
  r := register_commitment(conv, 'PAGO_PARCIAL_50', '{}', true);
  select status into s from intervention_steps where intervention_id=iv and step_type='COMMITMENT';
  insert into _t(paso,ok,detalle) values ('compromiso marca paso COMMITMENT', s='done', coalesce(r->>'receipt_code', r::text));
  select to_char(scheduled_for at time zone 'America/El_Salvador','DD/MM HH24:MI') into s from intervention_steps where intervention_id=iv and step_type='FOLLOW_UP';
  insert into _t(paso,ok,detalle) values ('seguimiento programado antes de la fecha', s is not null, s);
  select status into s from intervention_steps where intervention_id=iv and step_type='CONFIRMATION';
  insert into _t(paso,ok,detalle) values ('confirmación por correo queda pendiente para el servidor', s='pending', s);
  perform create_handoff(conv, 'whatsapp', 'SEND_PAYMENT_LINK');
  r := send_education(carlos, conv, 'record-crediticio', 'prueba', 'email');
  insert into _t(paso,ok,detalle) values ('video por correo queda enviado sin handoff', r->>'channel'='email'
    and (select status from education_deliveries where id = (r->>'delivery_id')::uuid)='sent'
    and not exists (select 1 from handoffs where payload->>'delivery_id' = r->>'delivery_id'), r->>'title');
  r := send_education(carlos, conv);
  insert into _t(paso,ok,detalle) values ('envía video por WhatsApp', (r->>'ok')::boolean
     and exists (select 1 from handoffs where action='SEND_EDUCATION' and payload->>'delivery_id' = r->>'delivery_id'), (r->>'title')||' · '||(r->>'url'));
  select status into s from intervention_steps where intervention_id=iv and step_type='EDUCATION';
  insert into _t(paso,ok,detalle) values ('paso EDUCATION avanza', s is not null and s <> 'pending', s);
  r := get_education_content(r->>'slug', (r->>'delivery_id')::uuid);
  insert into _t(paso,ok,detalle) values ('video visto queda registrado', exists (select 1 from education_deliveries where status='viewed'), r->>'title');
  perform evaluate_turn(conv, '{"identity_confirmed":"yes","confidence":0.9}');
  perform end_conversation(conv, 'PARTIAL_PAYMENT_AGREED');
  select string_agg(step_type||'='||status, ' ' order by step) into s from intervention_steps where intervention_id=iv;
  insert into _t(paso,ok,detalle) values ('al colgar CALL y UNDERSTAND quedan hechos', s like '%CALL=done%' and s like '%UNDERSTAND=done%', s);
  insert into _t(paso,ok,detalle) values ('contestó → correo de respaldo omitido', s like '%EMAIL=skipped%', s);
  insert into _t(paso,ok,detalle) values ('v_prevention_center devuelve filas', (select count(*) from v_prevention_center) > 0, (select count(*) from v_prevention_center)::text);
  insert into _t(paso,ok,detalle) values ('v_impact estima mora evitada', (select potential_delinquency_avoided from v_impact) > 0,
    (select 'evitada≈$'||potential_delinquency_avoided||' · comprometido $'||amount_committed from v_impact));
  insert into _t(paso,ok,detalle) values ('v_learning por grado×canal', (select count(*) from v_learning) > 0, (select string_agg(grade||'/'||channel||'='||commitment_rate_pct||'%', ' ') from v_learning));
  insert into _t(paso,ok,detalle) values ('perfil financiero con pago habitual', (select usual_payment_day is not null and avg_payment_amount > 0 from v_customer_financial_profile where customer_id=carlos),
    (select format('día %s · promedio $%s · último $%s (%s%%) · %s', usual_payment_day, avg_payment_amount, last_payment_amount, last_vs_avg_pct, trend) from v_customer_financial_profile where customer_id=carlos));
end $$;
-- @@ RESULTADOS
select n, case when ok then '✅' else '❌' end as r, paso, left(detalle, 120) detalle from _t order by n;
