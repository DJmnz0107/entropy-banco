-- Corrige bug de tipo: risk_score (int) recibía v_risk->>'band' (texto) en vez del puntaje numérico.
create or replace function run_detection() returns jsonb
language plpgsql as $$
declare
  v_run     uuid;
  cu        record;
  v_risk    jsonb;
  v_m       jsonb;
  v_status  text;
  v_channel text;
  n_eval int := 0; n_sched int := 0; n_block int := 0; n_ctrl int := 0; n_none int := 0;
begin
  insert into detection_runs default values returning id into v_run;

  for cu in
    select distinct c.id, c.is_control_group, c.consent_voice, c.consent_whatsapp, c.consent_sms, c.consent_email
      from customers c join loans l on l.customer_id = c.id and l.status = 'active'
  loop
    n_eval := n_eval + 1;
    v_risk := compute_risk(cu.id, true, 'detection');
    v_m    := match_rules(cu.id);

    if jsonb_array_length(v_m->'matched_rules') = 0 and not (v_m->>'blocked')::boolean then
      n_none := n_none + 1; continue;
    end if;
    if exists (select 1 from interventions where customer_id = cu.id and status in ('scheduled','dispatched')) then
      continue;
    end if;

    v_status := case when (v_m->>'blocked')::boolean then 'blocked'
                     when cu.is_control_group then 'control_group'
                     else 'scheduled' end;

    select ch into v_channel from jsonb_array_elements_text(v_m->'channel_sequence') ch
     where (ch = 'voice' and cu.consent_voice) or (ch = 'whatsapp' and cu.consent_whatsapp)
        or (ch = 'sms' and cu.consent_sms) or (ch = 'email' and cu.consent_email)
     limit 1;

    insert into interventions (customer_id, loan_id, risk_assessment_id, detection_run_id, status, priority,
                               risk_score, risk_band, matched_rules, block_reasons, offers, playbook_key,
                               channel_sequence, recommended_channel, reason, scheduled_for)
    values (cu.id, nullif(customer_facts(cu.id)->>'loan_id','')::uuid, (v_risk->>'id')::uuid, v_run, v_status,
            (v_risk->>'score')::int, (v_risk->>'score')::int, v_risk->>'band',
            v_m->'matched_rules', v_m->'block_reasons',
            (select coalesce(jsonb_agg(jsonb_build_object('code', o->>'code', 'name', o->>'name')), '[]')
               from jsonb_array_elements(v_m->'offers') o),
            v_m->>'playbook_key',
            array(select jsonb_array_elements_text(v_m->'channel_sequence')),
            v_channel,
            case v_status
              when 'blocked' then 'Bloqueado: ' || (select string_agg(b->>'name', '; ') from jsonb_array_elements(v_m->'block_reasons') b)
              when 'control_group' then 'Grupo de control: se mide sin contactar'
              else 'Reglas: ' || (select string_agg(x->>'name', '; ') from jsonb_array_elements(v_m->'matched_rules') x) end,
            next_contact_slot());

    case v_status when 'blocked' then n_block := n_block + 1;
                  when 'control_group' then n_ctrl := n_ctrl + 1;
                  else n_sched := n_sched + 1; end case;
  end loop;

  update detection_runs set finished_at = now(), customers_evaluated = n_eval, scheduled = n_sched,
         blocked = n_block, control_group = n_ctrl, no_action = n_none
   where id = v_run;

  return jsonb_build_object('detection_run_id', v_run, 'customers_evaluated', n_eval, 'scheduled', n_sched,
                            'blocked', n_block, 'control_group', n_ctrl, 'no_action', n_none);
end $$;
