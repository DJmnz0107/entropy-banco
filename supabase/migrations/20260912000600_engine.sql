-- ═══════════════════════════════════════════════════════════════════════════
-- 0600 · Motor: reglas, hechos, riesgo, detección, selección de modelos
-- Todo determinista. Ningún LLM decide aquí.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Evaluador de condiciones ──────────────────────────────────────────────
-- Un mismo lenguaje para reglas de cobranza Y para transiciones de etapa.
--   {"all":[...]} | {"any":[...]} | {"not":{...}} | {"fact":"x","op":"gte","value":2}
-- ops: eq neq gt gte lt lte between in not_in contains not_contains is_true is_false is_null exists
-- Un hecho ausente evalúa FALSE (salvo is_null).
create or replace function eval_condition(p_cond jsonb, p_facts jsonb) returns boolean
language plpgsql immutable as $$
declare
  v_item  jsonb;
  v_op    text;
  v_val   jsonb;
  v_fv    jsonb;
  v_n     numeric;
begin
  if p_cond is null or p_cond = '{}'::jsonb or jsonb_typeof(p_cond) = 'null' then
    return true;
  end if;

  if p_cond ? 'all' then
    for v_item in select * from jsonb_array_elements(p_cond -> 'all') loop
      if not eval_condition(v_item, p_facts) then return false; end if;
    end loop;
    return true;
  elsif p_cond ? 'any' then
    for v_item in select * from jsonb_array_elements(p_cond -> 'any') loop
      if eval_condition(v_item, p_facts) then return true; end if;
    end loop;
    return false;
  elsif p_cond ? 'not' then
    return not eval_condition(p_cond -> 'not', p_facts);
  end if;

  v_op  := p_cond ->> 'op';
  v_val := p_cond -> 'value';
  v_fv  := p_facts #> string_to_array(p_cond ->> 'fact', '.');

  if v_fv is null or jsonb_typeof(v_fv) = 'null' then
    return v_op = 'is_null';
  end if;

  v_n := jnum(v_fv);

  return coalesce(case v_op
    when 'eq'           then v_fv = v_val or (v_n is not null and v_n = jnum(v_val))
                             or lower(v_fv #>> '{}') = lower(v_val #>> '{}')
    when 'neq'          then not (v_fv = v_val or lower(v_fv #>> '{}') = lower(v_val #>> '{}'))
    when 'gt'           then v_n >  jnum(v_val)
    when 'gte'          then v_n >= jnum(v_val)
    when 'lt'           then v_n <  jnum(v_val)
    when 'lte'          then v_n <= jnum(v_val)
    when 'between'      then v_n between jnum(v_val -> 0) and jnum(v_val -> 1)
    when 'in'           then exists (select 1 from jsonb_array_elements(v_val) e
                                     where e = v_fv or lower(e #>> '{}') = lower(v_fv #>> '{}'))
    when 'not_in'       then not exists (select 1 from jsonb_array_elements(v_val) e
                                         where e = v_fv or lower(e #>> '{}') = lower(v_fv #>> '{}'))
    when 'contains'     then case when jsonb_typeof(v_fv) = 'array'
                                  then v_fv @> jsonb_build_array(v_val)
                                  else position(lower(v_val #>> '{}') in lower(v_fv #>> '{}')) > 0 end
    when 'not_contains' then case when jsonb_typeof(v_fv) = 'array'
                                  then not (v_fv @> jsonb_build_array(v_val))
                                  else position(lower(v_val #>> '{}') in lower(v_fv #>> '{}')) = 0 end
    when 'is_true'      then jbool(v_fv) is true
    when 'is_false'     then jbool(v_fv) is false
    when 'exists'       then true
    when 'is_null'      then false
    else false
  end, false);
end $$;

-- ─── Política activa ───────────────────────────────────────────────────────
create or replace function active_policy() returns agent_policies
language sql stable as $$
  select * from agent_policies where is_active limit 1
$$;

-- ─── Hechos del cliente ────────────────────────────────────────────────────
-- Todo lo que las reglas pueden consultar. Si agregas un hecho aquí, agrégalo
-- también a rule_fact_definitions para que aparezca en el constructor web.
create or replace function customer_facts(p_customer_id uuid) returns jsonb
language plpgsql stable as $$
declare
  v_today         date := sv_today();
  c               customers;
  l               loans;
  nx              installments;
  ra              risk_assessments;
  v_late12        int;
  v_total12       int;
  v_maxlate12     int;
  v_partial6      int;
  v_broken6       int;
  v_kept6         int;
  v_open_commit   int;
  v_contacts7     int;
  v_last_contact  timestamptz;
  v_overdue_amt   numeric;
  v_signals       jsonb;
  v_last_pay      timestamptz;
  v_months_harv   int;
begin
  select * into c from customers where id = p_customer_id;
  if c.id is null then return null; end if;

  -- préstamo "foco": el de la cuota impaga más antigua
  select lo.* into l
    from loans lo
    join installments i on i.loan_id = lo.id and i.status in ('pending','partial','overdue')
   where lo.customer_id = p_customer_id and lo.status = 'active'
   order by i.due_date asc
   limit 1;

  if l.id is not null then
    select * into nx from installments
     where loan_id = l.id and status in ('pending','partial','overdue')
     order by due_date asc limit 1;
  end if;

  select count(*) filter (where i.days_late > 0 or i.status = 'overdue'),
         count(*),
         coalesce(max(greatest(i.days_late, case when i.status = 'overdue' then v_today - i.due_date else 0 end)), 0)
    into v_late12, v_total12, v_maxlate12
    from installments i join loans lo on lo.id = i.loan_id
   where lo.customer_id = p_customer_id
     and i.due_date between v_today - 365 and v_today - 1;

  select count(*) into v_partial6
    from installments i join loans lo on lo.id = i.loan_id
   where lo.customer_id = p_customer_id
     and i.due_date between v_today - 180 and v_today
     and (select count(*) from payments p where p.installment_id = i.id) > 1;

  select count(*) filter (where status = 'broken'),
         count(*) filter (where status = 'kept'),
         count(*) filter (where status in ('pending','pending_approval','approved') and committed_date >= v_today)
    into v_broken6, v_kept6, v_open_commit
    from commitments
   where customer_id = p_customer_id and created_at >= now() - interval '180 days';

  select count(*) filter (where started_at >= now() - interval '7 days'), max(started_at)
    into v_contacts7, v_last_contact
    from conversations where customer_id = p_customer_id and status <> 'failed';

  select coalesce(sum(amount_due - amount_paid + late_fee), 0) into v_overdue_amt
    from installments i join loans lo on lo.id = i.loan_id
   where lo.customer_id = p_customer_id and i.status in ('partial','overdue','pending') and i.due_date < v_today;

  select coalesce(jsonb_agg(distinct signal_type), '[]'::jsonb) into v_signals
    from customer_signals
   where customer_id = p_customer_id and is_active and (expires_at is null or expires_at > now());

  select max(paid_at) into v_last_pay from payments where customer_id = p_customer_id;

  select * into ra from risk_assessments where customer_id = p_customer_id order by computed_at desc limit 1;

  if c.agro_profile ? 'harvest_months' then
    select min(((m::int - extract(month from v_today)::int) + 12) % 12) into v_months_harv
      from jsonb_array_elements_text(c.agro_profile -> 'harvest_months') m;
  end if;

  return jsonb_build_object(
    'customer_id',            c.id,
    'segment',                c.segment,
    'income_type',            c.income_type,
    'department',             c.department,
    'address_zone',           c.address_zone,
    'preferred_channel',      c.preferred_channel,
    'tenure_months',          (extract(year from age(v_today, coalesce(c.customer_since, v_today))) * 12
                               + extract(month from age(v_today, coalesce(c.customer_since, v_today))))::int,
    'opted_out',              c.opted_out_at is not null,
    'is_control_group',       c.is_control_group,
    'consent_voice',          c.consent_voice,
    'consent_whatsapp',       c.consent_whatsapp,
    'crop',                   c.agro_profile ->> 'crop',
    'dry_corridor',           coalesce(jbool(c.agro_profile -> 'dry_corridor'), false),
    'months_to_harvest',      v_months_harv
  ) || jsonb_build_object(
    'loan_id',                l.id,
    'product_type',           l.product_type,
    'balance',                l.balance,
    'installment_amount',     l.installment_amount,
    'debt_to_income',         case when coalesce(c.monthly_income, 0) > 0
                                   then round(l.installment_amount / c.monthly_income, 3) end,
    'next_installment_id',    nx.id,
    'next_due_date',          nx.due_date,
    'days_to_due',            case when nx.id is not null then nx.due_date - v_today end,
    'days_past_due',          case when nx.id is not null then greatest(0, v_today - nx.due_date) else 0 end,
    'amount_due',             case when nx.id is not null then nx.amount_due - nx.amount_paid end,
    'overdue_amount',         v_overdue_amt,
    'has_active_loan',        l.id is not null
  ) || jsonb_build_object(
    'late_payments_12m',      v_late12,
    'installments_12m',       v_total12,
    'on_time_ratio_12m',      case when v_total12 > 0 then round((v_total12 - v_late12)::numeric / v_total12, 3) else 1 end,
    'max_days_late_12m',      v_maxlate12,
    'partial_payments_6m',    v_partial6,
    'broken_commitments_6m',  v_broken6,
    'kept_commitments_6m',    v_kept6,
    'open_commitments',       v_open_commit,
    'contacts_last_7d',       v_contacts7,
    'days_since_last_contact', case when v_last_contact is not null then extract(day from now() - v_last_contact)::int end,
    'days_since_last_payment', case when v_last_pay is not null then extract(day from now() - v_last_pay)::int end,
    'signals',                v_signals,
    'signal_count',           jsonb_array_length(v_signals),
    'risk_score',             ra.score,
    'risk_band',              ra.band,
    'probability_default',    ra.probability_default,
    'local_hour',             extract(hour from sv_now())::int,
    'weekday',                extract(isodow from sv_today())::int
  );
end $$;

-- ─── Banda de riesgo según la política activa (único lugar) ───────────────
create or replace function risk_band_for(p_score numeric) returns text
language sql stable as $$
  select coalesce(
    (select key from jsonb_each((select risk_bands from agent_policies where is_active limit 1))
      where p_score between jnum(value->0) and jnum(value->1) limit 1),
    case when p_score >= 85 then 'CRITICO' when p_score >= 65 then 'ALTO' when p_score >= 45 then 'PREVENTIVO'
         when p_score >= 25 then 'MODERADO' else 'BAJO' end)
$$;

-- ─── Riesgo explicable (0-100) ─────────────────────────────────────────────
create or replace function compute_risk(p_customer_id uuid, p_persist boolean default true, p_trigger text default 'detection')
returns jsonb
language plpgsql as $$
declare
  f         jsonb := customer_facts(p_customer_id);
  pol       agent_policies := active_policy();
  w         jsonb;
  v_factors jsonb := '[]';
  v_score   numeric := 0;
  v_val     numeric;
  v_pts     numeric;
  v_band    text;
  v_pd      numeric;
  v_id      uuid;
  v_sig     numeric;
  v_commit  boolean;
begin
  if f is null then return null; end if;
  w := coalesce(pol.risk_weights, '{"due_proximity":20,"payment_history":25,"late_severity":15,"current_delinquency":15,"broken_commitments":5,"behavioral_signals":15,"debt_burden":5,"commitment_mitigation":12}'::jsonb);

  -- 1. proximidad de vencimiento
  v_val := case when jnum(f->'days_to_due') is null then 0
                when jnum(f->'days_to_due') < 0 then 1
                else greatest(0, least(1, (20 - jnum(f->'days_to_due')) / 20)) end;
  v_pts := round(v_val * jnum(w->'due_proximity'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','due_proximity','label','Proximidad de vencimiento',
     'weight', w->'due_proximity', 'value', round(v_val,3), 'points', v_pts,
     'detail', case when jnum(f->'days_to_due') is null then 'Sin cuotas pendientes'
                    when jnum(f->'days_to_due') < 0 then format('Cuota vencida hace %s días', -jnum(f->'days_to_due'))
                    else format('Cuota vence en %s días', f->>'days_to_due') end));
  v_score := v_score + v_pts;

  -- 2. historial de pagos (12 meses)
  v_val := least(1, (1 - coalesce(jnum(f->'on_time_ratio_12m'), 1)) / 0.35);
  v_pts := round(v_val * jnum(w->'payment_history'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','payment_history','label','Historial de atrasos (12 meses)',
     'weight', w->'payment_history', 'value', round(v_val,3), 'points', v_pts,
     'detail', format('%s de %s cuotas pagadas con atraso', f->>'late_payments_12m', f->>'installments_12m')));
  v_score := v_score + v_pts;

  -- 3. severidad del peor atraso
  v_val := least(1, coalesce(jnum(f->'max_days_late_12m'), 0) / 30);
  v_pts := round(v_val * jnum(w->'late_severity'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','late_severity','label','Severidad del peor atraso',
     'weight', w->'late_severity', 'value', round(v_val,3), 'points', v_pts,
     'detail', format('Peor atraso: %s días', f->>'max_days_late_12m')));
  v_score := v_score + v_pts;

  -- 4. mora actual
  v_val := least(1, coalesce(jnum(f->'days_past_due'), 0) / 10);
  v_pts := round(v_val * jnum(w->'current_delinquency'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','current_delinquency','label','Atraso actual',
     'weight', w->'current_delinquency', 'value', round(v_val,3), 'points', v_pts,
     'detail', case when coalesce(jnum(f->'days_past_due'),0) > 0 then format('%s días de atraso', f->>'days_past_due') else 'Al día' end));
  v_score := v_score + v_pts;

  -- 5. compromisos incumplidos
  v_val := least(1, coalesce(jnum(f->'broken_commitments_6m'), 0) / 2);
  v_pts := round(v_val * jnum(w->'broken_commitments'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','broken_commitments','label','Compromisos incumplidos (6 meses)',
     'weight', w->'broken_commitments', 'value', round(v_val,3), 'points', v_pts,
     'detail', format('%s compromisos incumplidos', f->>'broken_commitments_6m')));
  v_score := v_score + v_pts;

  -- 6. señales de comportamiento
  select coalesce(sum(case severity when 'high' then 0.6 when 'medium' then 0.35 else 0.15 end), 0)
    into v_sig
    from customer_signals cs join signal_definitions sd on sd.code = cs.signal_type
   where cs.customer_id = p_customer_id and cs.is_active and (cs.expires_at is null or cs.expires_at > now());
  v_val := least(1, v_sig);
  v_pts := round(v_val * jnum(w->'behavioral_signals'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','behavioral_signals','label','Señales tempranas de comportamiento',
     'weight', w->'behavioral_signals', 'value', round(v_val,3), 'points', v_pts,
     'detail', coalesce((select string_agg(sd.label, ', ') from customer_signals cs join signal_definitions sd on sd.code = cs.signal_type
                          where cs.customer_id = p_customer_id and cs.is_active), 'Sin señales activas')));
  v_score := v_score + v_pts;

  -- 7. carga de deuda
  v_val := least(1, coalesce(jnum(f->'debt_to_income'), 0) / 0.5);
  v_pts := round(v_val * jnum(w->'debt_burden'), 1);
  v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','debt_burden','label','Carga de la cuota sobre ingreso',
     'weight', w->'debt_burden', 'value', round(v_val,3), 'points', v_pts,
     'detail', format('La cuota representa %s%% del ingreso', round(coalesce(jnum(f->'debt_to_income'),0) * 100))));
  v_score := v_score + v_pts;

  -- 8. mitigación: compromiso vigente (resta)
  v_commit := coalesce(jnum(f->'open_commitments'), 0) > 0;
  if v_commit then
    v_pts := -jnum(w->'commitment_mitigation');
    v_factors := v_factors || jsonb_build_array(jsonb_build_object('key','commitment_mitigation','label','Compromiso de pago vigente',
       'weight', w->'commitment_mitigation', 'value', 1, 'points', v_pts, 'detail', 'El cliente tiene un compromiso activo'));
    v_score := v_score + v_pts;
  end if;

  v_score := greatest(0, least(100, round(v_score)));

  v_band := risk_band_for(v_score);

  v_pd := round(1 / (1 + exp(-(v_score - 65) / 12.0)), 4);

  select jsonb_agg(x order by jnum(x->'points') desc) into v_factors from jsonb_array_elements(v_factors) x;

  if p_persist then
    insert into risk_assessments (customer_id, loan_id, score, band, probability_default, factors, facts, trigger)
    values (p_customer_id, (f->>'loan_id')::uuid, v_score, v_band, v_pd, v_factors, f, p_trigger)
    returning id into v_id;
  end if;

  return jsonb_build_object('id', v_id, 'score', v_score, 'band', v_band,
                            'probability_default', v_pd, 'factors', v_factors);
end $$;

-- ─── Reglas de cobranza → ofertas permitidas + playbook ────────────────────
create or replace function match_rules(p_customer_id uuid, p_facts jsonb default null) returns jsonb
language plpgsql stable as $$
declare
  f          jsonb := coalesce(p_facts, customer_facts(p_customer_id));
  pol        agent_policies := active_policy();
  r          collection_rules;
  o          record;
  v_matched  jsonb := '[]';
  v_blocks   jsonb := '[]';
  v_offers   jsonb := '[]';
  v_seen     text[] := '{}';
  v_cons     jsonb := '{}';
  v_playbook text;
  v_tone     text;
  v_channels text[];
  k          text;
  val        jsonb;
begin
  for r in select * from collection_rules where is_active order by priority desc, key loop
    if not eval_condition(r.conditions, f) then continue; end if;

    if r.effect = 'block' then
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object('key', r.key, 'name', r.name, 'reason', r.description));
      continue;
    end if;

    v_matched := v_matched || jsonb_build_array(jsonb_build_object(
      'key', r.key, 'name', r.name, 'priority', r.priority, 'playbook_key', r.playbook_key, 'tone', r.tone));
    v_playbook := coalesce(v_playbook, r.playbook_key);
    v_tone     := coalesce(v_tone, r.tone);
    v_channels := coalesce(v_channels, r.channel_sequence);

    -- Ofertas: unión sin duplicados, en orden de prioridad de regla y posición
    for o in
      select ofr.*, ro.position
        from rule_offers ro join offers ofr on ofr.id = ro.offer_id
       where ro.rule_id = r.id and ofr.is_active
       order by ro.position
    loop
      if o.code = any(v_seen) or not eval_condition(o.eligibility, f) then continue; end if;
      v_seen := v_seen || o.code;
      v_offers := v_offers || jsonb_build_array(jsonb_build_object(
        'code', o.code, 'name', o.name, 'offer_type', o.offer_type, 'description', o.description,
        'pitch_script', o.pitch_script, 'terms_template', o.terms_template, 'cta_label', o.cta_label,
        'params', o.params, 'requires_approval', o.requires_approval,
        'disclosure_required', o.disclosure_required, 'generates_payment_link', o.generates_payment_link,
        'from_rule', r.key));
    end loop;

    -- Restricciones: la más restrictiva gana
    for k, val in select * from jsonb_each(r.constraints) loop
      if not (v_cons ? k) then
        v_cons := v_cons || jsonb_build_object(k, val);
      elsif k like 'max\_%' then
        v_cons := jsonb_set(v_cons, array[k], to_jsonb(least(jnum(v_cons->k), jnum(val))));
      elsif k like 'min\_%' then
        v_cons := jsonb_set(v_cons, array[k], to_jsonb(greatest(jnum(v_cons->k), jnum(val))));
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'blocked',              jsonb_array_length(v_blocks) > 0,
    'block_reasons',        v_blocks,
    'matched_rules',        v_matched,
    'offers',               v_offers,
    'max_offers_presented', coalesce(pol.max_offers_presented, 3),
    'playbook_key',         coalesce(v_playbook, pol.default_playbook_key),
    'tone',                 coalesce(v_tone, 'calido'),
    'channel_sequence',     to_jsonb(coalesce(v_channels, array['whatsapp'])),
    'constraints',          v_cons
  );
end $$;

-- ─── Modelos a usar (experimento → defaults de política) ───────────────────
create or replace function pick_experiment_arm(p_experiment_key text, p_unit text) returns jsonb
language plpgsql stable as $$
declare
  v_total  int;
  v_bucket int;
  v_acc    int := 0;
  a        record;
begin
  select coalesce(sum(ea.traffic_weight), 0) into v_total
    from experiment_arms ea join experiments e on e.id = ea.experiment_id
   where e.key = p_experiment_key and e.status = 'running';
  if v_total = 0 then return null; end if;

  v_bucket := floor(drand(p_experiment_key || ':' || p_unit) * v_total)::int;
  for a in
    select ea.*, e.id as exp_id from experiment_arms ea join experiments e on e.id = ea.experiment_id
     where e.key = p_experiment_key order by ea.arm_key
  loop
    v_acc := v_acc + a.traffic_weight;
    if v_bucket < v_acc then
      return jsonb_build_object('experiment_id', a.exp_id, 'experiment_key', p_experiment_key, 'arm_key', a.arm_key,
        'voice_realtime', a.voice_model_key, 'supervisor', a.supervisor_model_key, 'composer', a.composer_model_key,
        'voice_mode', a.param_overrides ->> 'voice_mode', 'stt', a.param_overrides ->> 'stt', 'tts', a.param_overrides ->> 'tts',
        'prompt_overrides', a.prompt_overrides, 'param_overrides', a.param_overrides);
    end if;
  end loop;
  return null;
end $$;

-- Devuelve la configuración COMPLETA de cada modelo (params, VAD, interrupciones)
create or replace function resolve_models(p_arm jsonb default null) returns jsonb
language plpgsql stable as $$
declare
  pol    agent_policies := active_policy();
  v_out  jsonb := '{}';
  r      text;
  v_key  text;
begin
  foreach r in array array['voice_mode','voice_realtime','stt','tts','supervisor','composer','multimodal','summarizer'] loop
    if r = 'voice_mode' then
      v_out := v_out || jsonb_build_object('voice_mode', coalesce(p_arm ->> 'voice_mode', pol.default_models ->> 'voice_mode', 'realtime'));
      continue;
    end if;
    v_key := coalesce(p_arm ->> r, pol.default_models ->> r);
    if v_key is not null then
      v_out := v_out || jsonb_build_object(r, (
        select jsonb_build_object('key', m.key, 'provider', m.provider, 'model_id', m.model_id,
               'params', m.params || coalesce(p_arm -> 'param_overrides', '{}'),
               'vad_config', m.vad_config,
               'interruption_config', pol.interruption_policy || m.interruption_config,
               'capabilities', m.capabilities, 'pricing', m.pricing)
          from ai_model_profiles m where m.key = v_key));
    end if;
  end loop;
  return v_out;
end $$;

-- ─── Siguiente horario permitido de contacto ───────────────────────────────
create or replace function next_contact_slot() returns timestamptz
language plpgsql stable as $$
declare
  pol     agent_policies := active_policy();
  v_local timestamp := sv_now();
  v_start time := coalesce((pol.quiet_hours->>'end')::time, '08:00');
  v_end   time := coalesce((pol.quiet_hours->>'start')::time, '20:00');
  v_slot  timestamp;
begin
  if v_local::time >= v_start and v_local::time < v_end
     and not (extract(isodow from v_local)::int = any(pol.forbidden_weekdays)) then
    return now();
  end if;
  v_slot := case when v_local::time >= v_end then (v_local::date + 1) + v_start else v_local::date + v_start end;
  while extract(isodow from v_slot)::int = any(pol.forbidden_weekdays) loop
    v_slot := v_slot + interval '1 day';
  end loop;
  return v_slot at time zone 'America/El_Salvador';
end $$;

-- ─── Contexto completo para voz / WhatsApp (EL contrato) ──────────────────
create or replace function get_conversation_context(p_customer_id uuid) returns jsonb
language plpgsql as $$
declare
  c         customers;
  f         jsonb;
  v_risk    jsonb;
  v_rules   jsonb;
  pol       agent_policies := active_policy();
  pb        playbooks;
  l         loans;
begin
  select * into c from customers where id = p_customer_id;
  if c.id is null then raise exception 'CLIENTE_NO_EXISTE: %', p_customer_id; end if;

  select to_jsonb(ra) - 'facts' into v_risk from risk_assessments ra
   where ra.customer_id = p_customer_id order by computed_at desc limit 1;
  if v_risk is null then
    v_risk := compute_risk(p_customer_id, true, 'context');
  end if;

  f := customer_facts(p_customer_id);
  v_rules := match_rules(p_customer_id, f);
  select * into pb from playbooks where key = v_rules->>'playbook_key';
  select * into l from loans where id = (f->>'loan_id')::uuid;

  return jsonb_build_object(
    'generated_at', now(),
    'customer', jsonb_build_object(
      'id', c.id, 'code', c.customer_code, 'first_name', c.first_name, 'full_name', c.full_name,
      'gender', c.gender, 'segment', c.segment, 'department', c.department, 'city', c.city,
      'income_type', c.income_type, 'occupation', c.occupation, 'agro_profile', c.agro_profile,
      'preferred_channel', c.preferred_channel, 'preferred_contact_window', c.preferred_contact_window,
      'language', c.language, 'customer_since', c.customer_since, 'contact_enabled', c.contact_enabled,
      'is_control_group', c.is_control_group),
    'loan', case when l.id is null then null else jsonb_build_object(
      'id', l.id, 'loan_number', l.loan_number, 'product_type', l.product_type, 'product_name', l.product_name,
      'purpose', l.purpose, 'principal', l.principal, 'balance', l.balance, 'installment_amount', l.installment_amount,
      'next_due_date', f->'next_due_date', 'next_due_date_text', fmt_date_es((f->>'next_due_date')::date),
      'days_to_due', f->'days_to_due', 'days_past_due', f->'days_past_due',
      'amount_due', f->'amount_due', 'amount_due_text', fmt_money(jnum(f->'amount_due')),
      'overdue_amount', f->'overdue_amount', 'late_fee_amount', l.late_fee_amount) end,
    'payment_behavior', jsonb_build_object(
      'late_payments_12m', f->'late_payments_12m', 'installments_12m', f->'installments_12m',
      'on_time_ratio_12m', f->'on_time_ratio_12m', 'max_days_late_12m', f->'max_days_late_12m',
      'days_since_last_payment', f->'days_since_last_payment',
      'last_installments', (select coalesce(jsonb_agg(x order by x->>'due_date' desc), '[]') from (
          select jsonb_build_object('due_date', i.due_date, 'amount_due', i.amount_due, 'paid_at', i.paid_at,
                                    'days_late', i.days_late, 'status', i.status) x
            from installments i where i.loan_id = l.id and i.due_date < sv_today()
           order by i.due_date desc limit 6) s)),
    'risk', jsonb_build_object('score', v_risk->'score', 'band', v_risk->'band',
                               'probability_default', v_risk->'probability_default',
                               'top_factors', (select coalesce(jsonb_agg(x), '[]') from (
                                   select x from jsonb_array_elements(v_risk->'factors') x
                                    where jnum(x->'points') > 0 limit 3) s)),
    'signals', (select coalesce(jsonb_agg(jsonb_build_object('type', cs.signal_type, 'label', sd.label,
                   'severity', cs.severity, 'detail', cs.detail, 'detected_at', cs.detected_at)
                   order by cs.detected_at desc), '[]')
                  from customer_signals cs join signal_definitions sd on sd.code = cs.signal_type
                 where cs.customer_id = p_customer_id and cs.is_active),
    'rules', jsonb_build_object('blocked', v_rules->'blocked', 'block_reasons', v_rules->'block_reasons',
                                'matched', v_rules->'matched_rules', 'tone', v_rules->'tone',
                                'channel_sequence', v_rules->'channel_sequence'),
    'offers', v_rules->'offers',
    'max_offers_presented', v_rules->'max_offers_presented',
    'constraints', v_rules->'constraints',
    'playbook', jsonb_build_object('key', pb.key, 'name', pb.name, 'description', pb.description,
      'stages', (select coalesce(jsonb_agg(jsonb_build_object(
                    'key', s.stage_key, 'position', s.position, 'name', s.name, 'objective', s.objective,
                    'instructions', s.agent_instructions, 'criteria', to_jsonb(s.criteria),
                    'max_turns', s.max_turns, 'allows_offers', s.allows_offers,
                    'is_terminal', s.is_terminal, 'suggested_outcome', s.suggested_outcome)
                  order by s.position), '[]')
                  from playbook_stages s where s.playbook_id = pb.id)),
    'criteria_catalog', (select coalesce(jsonb_agg(jsonb_build_object('key', ec.key, 'label', ec.label,
                           'description', ec.description, 'type', ec.value_type, 'options', ec.options)
                           order by ec.sort_order), '[]') from evaluation_criteria ec),
    'policies', jsonb_build_object(
      'assistant_name', pol.assistant_name, 'disclosure_text', pol.disclosure_text,
      'max_turns_per_conversation', pol.max_turns_per_conversation,
      'pace_instructions', pol.pace_instructions, 'interruption_policy', pol.interruption_policy,
      'prohibited_phrases', to_jsonb(pol.prohibited_phrases)),
    'history', jsonb_build_object(
      'previous_conversations', (select coalesce(jsonb_agg(x), '[]') from (
          select jsonb_build_object('started_at', cv.started_at, 'channel', cv.channel, 'outcome', cv.outcome,
                                    'summary', cv.summary, 'sentiment_end', cv.sentiment_end) x
            from conversations cv where cv.customer_id = p_customer_id and cv.status <> 'active'
           order by cv.started_at desc limit 5) s),
      'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('offer_code', cm.offer_code,
          'amount', cm.amount, 'committed_date', cm.committed_date, 'status', cm.status, 'receipt_code', cm.receipt_code)), '[]')
          from commitments cm where cm.customer_id = p_customer_id and cm.status in ('pending','pending_approval','approved')),
      'broken_commitments_6m', f->'broken_commitments_6m'),
    'facts', f
  );
end $$;

-- ─── Detección preventiva (botón "Ejecutar detección" en la web) ───────────
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
