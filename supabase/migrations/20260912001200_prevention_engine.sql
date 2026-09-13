-- ═══════════════════════════════════════════════════════════════════════════
-- 1200 · Motor de Prevención — Next Best Intervention
--
--   preventive_grade / ssf_category      calificación preventiva A–E + categoría SSF
--   v_customer_financial_profile         "ADN financiero" del cliente
--   channel_propensity                   qué canal responde mejor (tasas observadas + suavizado)
--   education_contents / deliveries      banco de videos de educación financiera
--   next_best_intervention               QUÉ hacer, POR QUÉ, CÓMO, qué ofrecer y el plan
--   prevention_runs / run_prevention     la "corrida" con datos actualizados
--   intervention_steps                   plan por pasos (se actualiza solo con triggers)
--   v_prevention_center, v_impact, v_learning
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Calificaciones ────────────────────────────────────────────────────────
-- Preventiva (propia, hacia adelante): A = mejor pagador … E = mayor riesgo.
create or replace function preventive_grade(p_score numeric) returns text
language sql stable as $$
  select case risk_band_for(p_score)
    when 'BAJO' then 'A' when 'MODERADO' then 'B' when 'PREVENTIVO' then 'C' when 'ALTO' then 'D' else 'E' end
$$;

-- Regulatoria (hacia atrás, por días de atraso). Referencia NCB-022 créditos de consumo — verificar tabla oficial.
create or replace function ssf_category(p_days_past_due int) returns text
language sql immutable as $$
  select case
    when coalesce(p_days_past_due, 0) <= 7   then 'A1'
    when p_days_past_due <= 30  then 'A2'
    when p_days_past_due <= 60  then 'B'
    when p_days_past_due <= 90  then 'C1'
    when p_days_past_due <= 120 then 'C2'
    when p_days_past_due <= 150 then 'D1'
    when p_days_past_due <= 180 then 'D2'
    else 'E' end
$$;

create or replace function pd_from_score(p_score numeric) returns numeric
language sql immutable as $$ select round(1 / (1 + exp(-(coalesce(p_score, 0) - 65) / 12.0)), 4) $$;

-- ─── Banco de videos de educación financiera ──────────────────────────────
create table education_contents (
  id                 uuid primary key default gen_random_uuid(),
  slug               text unique not null,
  title              text not null,
  description        text,
  topic              text,
  duration_s         int not null default 20,
  video_url          text,                -- subir video (Storage/YouTube). null = la web muestra tarjetas con el guion
  thumbnail_url      text,
  script             text not null,       -- guion de 15–20 s (sirve para generar el video/voz)
  target_conditions  jsonb not null default '{}',   -- mismo lenguaje de condiciones que las reglas
  priority           int not null default 50,
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);

create table education_deliveries (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null references customers(id) on delete cascade,
  content_id       uuid not null references education_contents(id) on delete cascade,
  conversation_id  uuid references conversations(id) on delete set null,
  intervention_id  uuid references interventions(id) on delete set null,
  channel          text not null default 'whatsapp',
  status           text not null default 'queued' check (status in ('queued','sent','viewed','failed')),
  reason           text,
  url              text,
  sent_at          timestamptz,
  viewed_at        timestamptz,
  created_at       timestamptz not null default now()
);
create index on education_deliveries (customer_id, created_at desc);

-- ─── Corridas y plan de intervención ──────────────────────────────────────
create table prevention_runs (
  id                       uuid primary key default gen_random_uuid(),
  created_by               text,
  filters                  jsonb not null default '{}',
  status                   text not null default 'preview' check (status in ('preview','dispatched','completed','cancelled')),
  customers_evaluated      int not null default 0,
  requiring_intervention   int not null default 0,
  blocked                  int not null default 0,
  control_group            int not null default 0,
  by_action                jsonb not null default '{}',
  by_grade                 jsonb not null default '{}',
  amount_at_risk           numeric(14,2) not null default 0,
  expected_avoided_amount  numeric(14,2) not null default 0,
  dispatch_summary         jsonb,
  dispatched_at            timestamptz,
  created_at               timestamptz not null default clock_timestamp()   -- varias corridas en una transacción no empatan
);

alter table interventions
  add column prevention_run_id        uuid references prevention_runs(id) on delete set null,
  add column grade                    text,
  add column action                   text,
  add column next_best                jsonb,
  add column amount_at_risk           numeric(12,2),
  add column expected_avoided_amount  numeric(12,2);
create index on interventions (prevention_run_id);

create table intervention_steps (
  id               uuid primary key default gen_random_uuid(),
  intervention_id  uuid not null references interventions(id) on delete cascade,
  customer_id      uuid not null references customers(id) on delete cascade,
  step             int not null,
  step_type        text not null,   -- CALL UNDERSTAND OFFER COMMITMENT WHATSAPP EDUCATION FOLLOW_UP REMINDER HUMAN
  label            text not null,
  status           text not null default 'pending' check (status in ('pending','in_progress','done','skipped','failed')),
  scheduled_for    timestamptz,
  completed_at     timestamptz,
  conversation_id  uuid references conversations(id) on delete set null,
  detail           jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  unique (intervention_id, step)
);
create index on intervention_steps (customer_id, status);

-- Política de canales de la corrida (editable desde la web)
alter table agent_policies
  add column channel_by_grade             jsonb   not null default '{"A":"email","B":"email","C":"voice","D":"voice","E":"voice"}',
  add column email_fallback               boolean not null default true,   -- C–E que no contestan → correo
  add column max_calls_per_run            int     not null default 5,      -- llamadas REALES por corrida (seguro de costo)
  add column max_simulated_calls_per_run  int     not null default 3,      -- llamadas simuladas (sin ElevenLabs)
  add column email_from                   text    not null default 'Bancoagrícola Demo <onboarding@resend.dev>';

-- Handoff para enviar videos; rol "telephony" para costear llamadas
alter table handoffs drop constraint if exists handoffs_action_check;
alter table handoffs add constraint handoffs_action_check check (action in
  ('SEND_PAYMENT_LINK','SEND_COMMITMENT_SUMMARY','SEND_OFFER_DETAILS','FOLLOW_UP_MESSAGE','CALLBACK','SEND_EDUCATION'));
alter table ai_model_profiles drop constraint if exists ai_model_profiles_role_check;
alter table ai_model_profiles add constraint ai_model_profiles_role_check check (role in
  ('voice_realtime','stt','tts','telephony','supervisor','composer','multimodal','summarizer','customer_simulator','judge'));
alter table ai_model_profiles drop constraint if exists ai_model_profiles_modality_check;
alter table ai_model_profiles add constraint ai_model_profiles_modality_check check (modality in
  ('realtime_audio','speech_to_text','text_to_speech','text','multimodal','telephony'));

-- ─── ADN financiero ────────────────────────────────────────────────────────
create or replace view v_customer_financial_profile with (security_invoker = true) as
select
  c.id as customer_id, c.customer_code, c.full_name, c.first_name, c.segment, c.income_type, c.monthly_income,
  c.preferred_channel, c.preferred_contact_window, c.contact_enabled, c.is_control_group,
  f.product_name, f.installment_amount, f.amount_due, f.next_due_date, f.days_to_due, f.days_past_due,
  r.score as risk_score, r.band as risk_band, r.probability_default,
  preventive_grade(r.score) as grade, ssf_category(f.days_past_due) as ssf_category,
  p.usual_payment_day, p.avg_payment_amount, p.last_payment_amount, p.last_payment_at,
  case when p.avg_payment_amount > 0 then round(100 * (p.last_payment_amount - p.avg_payment_amount) / p.avg_payment_amount) end as last_vs_avg_pct,
  h.late_last_6, h.late_recent_3, h.late_previous_3,
  case when h.late_recent_3 > h.late_previous_3 then 'empeorando'
       when h.late_recent_3 < h.late_previous_3 then 'mejorando' else 'estable' end as trend,
  coalesce(ct.best_window, c.preferred_contact_window) as best_contact_window,
  ct.voice_attempts, ct.voice_responses, ct.whatsapp_attempts, ct.whatsapp_responses,
  ct.last_outcome, ct.last_contact_at
from customers c
left join v_latest_risk r on r.customer_id = c.id
left join lateral (
  select l.product_name, l.installment_amount, i.amount_due - i.amount_paid as amount_due, i.due_date as next_due_date,
         i.due_date - sv_today() as days_to_due, greatest(0, sv_today() - i.due_date) as days_past_due
    from loans l join installments i on i.loan_id = l.id and i.status in ('pending','partial','overdue')
   where l.customer_id = c.id and l.status = 'active' order by i.due_date limit 1
) f on true
left join lateral (
  select mode() within group (order by extract(day from x.paid_at)::int) as usual_payment_day,
         round(avg(x.total), 2) as avg_payment_amount,
         (array_agg(x.total order by x.paid_at desc))[1] as last_payment_amount,
         max(x.paid_at) as last_payment_at
    from (select pm.installment_id, sum(pm.amount) as total, max(pm.paid_at) as paid_at
            from payments pm where pm.customer_id = c.id
           group by pm.installment_id order by max(pm.paid_at) desc limit 12) x
) p on true
left join lateral (
  select count(*) filter (where y.days_late > 0) as late_last_6,
         count(*) filter (where y.days_late > 0 and y.rn <= 3) as late_recent_3,
         count(*) filter (where y.days_late > 0 and y.rn > 3) as late_previous_3
    from (select i.days_late, row_number() over (order by i.due_date desc) as rn
            from installments i join loans l on l.id = i.loan_id
           where l.customer_id = c.id and i.due_date < sv_today() and i.status in ('paid','paid_late','partial','overdue','rescheduled')
           order by i.due_date desc limit 6) y
) h on true
left join lateral (
  select count(*) filter (where cv.channel = 'voice') as voice_attempts,
         count(*) filter (where cv.channel = 'voice' and z.responded) as voice_responses,
         count(*) filter (where cv.channel = 'whatsapp') as whatsapp_attempts,
         count(*) filter (where cv.channel = 'whatsapp' and z.responded) as whatsapp_responses,
         (array_agg(cv.outcome order by cv.started_at desc))[1] as last_outcome,
         max(cv.started_at) as last_contact_at,
         mode() within group (order by case when extract(hour from cv.started_at at time zone 'America/El_Salvador') < 12 then 'manana'
                                            when extract(hour from cv.started_at at time zone 'America/El_Salvador') < 18 then 'tarde'
                                            else 'noche' end) filter (where z.responded) as best_window
    from conversations cv
    cross join lateral (select exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer') as responded) z
   where cv.customer_id = c.id and cv.status <> 'active'
) ct on true;

-- ─── Propensión por canal: tasas observadas por grado + historial del cliente ──
create or replace function channel_propensity(p_customer_id uuid, p_grade text default null) returns jsonb
language plpgsql stable as $$
declare
  k       constant numeric := 3;   -- suavizado: peso del promedio del grupo
  c       customers;
  v_grade text := p_grade;
  v_out   jsonb := '{}';
  ch      text;
  pr      record;
  own     record;
  v_resp  numeric;
  v_succ  numeric;
begin
  select * into c from customers where id = p_customer_id;
  if v_grade is null then
    select preventive_grade(score) into v_grade from v_latest_risk where customer_id = p_customer_id;
  end if;

  foreach ch in array array['voice','whatsapp'] loop
    -- promedio del grupo (mismo grado) con piso para grupos sin datos
    select count(*) as n,
           coalesce(avg(case when exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer') then 1 else 0 end), 0) as resp,
           coalesce(avg(case when cv.commitment_id is not null then 1 else 0 end), 0) as commit_rate
      into pr
      from conversations cv
     where cv.channel = ch and cv.status <> 'active' and preventive_grade(cv.risk_before) = v_grade;

    select count(*) as n,
           count(*) filter (where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) as responses
      into own
      from conversations cv where cv.customer_id = p_customer_id and cv.channel = ch and cv.status <> 'active';

    v_resp := (own.responses + (case when pr.n > 0 then pr.resp else 0.6 end) * k) / (own.n + k);
    v_succ := v_resp * (case when pr.n > 0 and pr.resp > 0 then least(1, pr.commit_rate / pr.resp) else 0.5 end);

    if (ch = 'voice' and not c.consent_voice) or (ch = 'whatsapp' and not c.consent_whatsapp) then
      v_resp := 0; v_succ := 0;
    end if;

    v_out := v_out || jsonb_build_object(ch, jsonb_build_object(
      'response', round(v_resp, 3), 'success', round(v_succ, 3),
      'attempts', own.n, 'responses', own.responses, 'group_size', pr.n,
      'group_response_rate', round(pr.resp, 3), 'group_commitment_rate', round(pr.commit_rate, 3)));
  end loop;

  return v_out || jsonb_build_object('grade', v_grade,
    'method', 'Tasa observada del cliente suavizada con el promedio de su grado (k=3). Se recalcula con cada interacción.');
end $$;

-- ─── Elegir video ──────────────────────────────────────────────────────────
create or replace function pick_education(p_customer_id uuid, p_facts jsonb default null) returns jsonb
language plpgsql stable as $$
declare
  f  jsonb := coalesce(p_facts, customer_facts(p_customer_id));
  e  education_contents;
begin
  for e in select * from education_contents where is_active order by priority desc, slug loop
    continue when exists (select 1 from education_deliveries d where d.customer_id = p_customer_id and d.content_id = e.id
                            and d.created_at > now() - interval '30 days');
    if eval_condition(e.target_conditions, f) then
      return jsonb_build_object('id', e.id, 'slug', e.slug, 'title', e.title, 'duration_s', e.duration_s,
                                'topic', e.topic, 'video_url', e.video_url);
    end if;
  end loop;
  return null;
end $$;

-- ─── NEXT BEST INTERVENTION ────────────────────────────────────────────────
create or replace function next_best_intervention(p_customer_id uuid, p_facts jsonb default null) returns jsonb
language plpgsql stable as $$
declare
  c         customers;
  f         jsonb := coalesce(p_facts, customer_facts(p_customer_id));
  ra        v_latest_risk;
  m         jsonb;
  prop      jsonb;
  prof      v_customer_financial_profile;
  edu       jsonb;
  v_grade   text;
  v_ssf     text;
  v_action  text;
  v_channel text;
  v_why     jsonb := '[]';
  v_whych   text;
  v_plan    jsonb := '[]';
  v_offers  jsonb;
  v_amount  numeric;
  v_pd      numeric;
  v_succ    numeric;
  v_chseq   text[];
  v_top     text;
  v_prio    numeric;
  v_block   text;
  v_negotiate boolean := false;
  v_pol     agent_policies := active_policy();
  v_policy_ch text;
  v_sv      numeric;
  v_sw      numeric;
begin
  select * into c from customers where id = p_customer_id;
  if c.id is null then return null; end if;
  select * into ra from v_latest_risk where customer_id = p_customer_id;
  select * into prof from v_customer_financial_profile where customer_id = p_customer_id;

  m       := match_rules(p_customer_id, f);
  v_grade := preventive_grade(ra.score);
  v_ssf   := ssf_category(coalesce(jnum(f->'days_past_due'), 0)::int);
  prop    := channel_propensity(p_customer_id, v_grade);
  edu     := pick_education(p_customer_id, f);
  v_amount := coalesce(jnum(f->'amount_due'), 0);
  v_pd     := coalesce(ra.probability_default, pd_from_score(ra.score));
  v_chseq  := array(select jsonb_array_elements_text(m->'channel_sequence'));
  select coalesce(jsonb_agg(jsonb_build_object('code', o->>'code', 'name', o->>'name')), '[]') into v_offers
    from (select o from jsonb_array_elements(m->'offers') o limit 3) s;

  -- Por qué: factores con puntos + señales del perfil
  select coalesce(jsonb_agg(x->>'detail'), '[]') into v_why
    from (select x from jsonb_array_elements(ra.factors) x where jnum(x->'points') > 0 limit 4) s;
  if prof.last_vs_avg_pct is not null and prof.last_vs_avg_pct <= -15 then
    v_why := v_why || to_jsonb(format('Último pago %s%% menor a su promedio', abs(prof.last_vs_avg_pct)));
  end if;
  if prof.trend = 'empeorando' then v_why := v_why || to_jsonb('Patrón de pago empeorando en los últimos 3 meses'::text); end if;

  -- Decisión
  if (m->>'blocked')::boolean then
    v_action := 'BLOCKED';
    v_block  := (select string_agg(b->>'name', '; ') from jsonb_array_elements(m->'block_reasons') b);
  elsif c.is_control_group then
    v_action := 'MONITOR';
    v_block  := 'Grupo de control: se mide sin contactar';
  elsif coalesce(jnum(f->'days_past_due'), 0) > 30 then
    v_action := 'HUMAN'; v_channel := 'human';
    v_why := v_why || to_jsonb('Atraso mayor a 30 días: ya es recuperación, requiere asesor'::text);
  elsif prof.last_outcome in ('HUMAN_ESCALATION','EXPLICIT_REFUSAL') and prof.last_contact_at > now() - interval '30 days' then
    v_action := 'HUMAN'; v_channel := 'human';
    v_why := v_why || to_jsonb(format('Última interacción terminó en %s: mejor atención humana', prof.last_outcome));
  elsif v_grade in ('A','B') and jsonb_array_length(m->'matched_rules') = 0 and edu is null then
    v_action := 'MONITOR';
  else
    -- Política de canal por grado (agent_policies.channel_by_grade, editable desde la web):
    --   'voice' = llama el agente · 'email' = correo · 'whatsapp' · 'auto' = canal con mayor éxito esperado
    v_policy_ch := coalesce(v_pol.channel_by_grade ->> v_grade, case when v_grade in ('A','B') then 'email' else 'voice' end);
    v_negotiate := exists (select 1 from jsonb_array_elements(m->'offers') o
                            where o->>'offer_type' in ('DATE_EXTENSION','INSTALLMENT_PLAN','PARTIAL_PAYMENT'))
                   and (coalesce(jnum(f->'late_payments_12m'), 0) >= 2 or jsonb_array_length(f->'signals') > 0);

    if v_policy_ch = 'auto' then
      --   · preferencia declarada del cliente (+15%)
      --   · necesidad de negociar (plan / extensión / parcial con atrasos o señales): la voz +20%
      v_sv := coalesce(jnum(prop->'voice'->'success'), 0)
              * (case when c.preferred_channel = 'voice' then 1.15 else 1 end)
              * (case when v_negotiate then 1.20 else 1 end);
      v_sw := coalesce(jnum(prop->'whatsapp'->'success'), 0)
              * (case when c.preferred_channel = 'whatsapp' then 1.15 else 1 end);
      v_channel := case when v_sv >= v_sw and ('voice' = any(v_chseq) or cardinality(v_chseq) = 0) then 'voice' else 'whatsapp' end;
    else
      v_channel := v_policy_ch;
    end if;

    -- consentimiento: si no puede por ese canal, correo; si tampoco, no se contacta
    if v_channel = 'voice' and not c.consent_voice then v_channel := 'email'; end if;
    if v_channel = 'whatsapp' and not c.consent_whatsapp then v_channel := 'email'; end if;
    if v_channel = 'email' and not c.consent_email then v_channel := null; end if;

    v_action := case v_channel
      when 'voice'    then case when v_negotiate then 'CALL_ALTERNATIVE_DATE' else 'CALL_NOW' end
      when 'whatsapp' then 'WHATSAPP'
      when 'email'    then 'EMAIL_REMINDER'
      else 'MONITOR' end;
    if v_channel is null then v_block := 'Sin consentimiento para ningún canal'; end if;
  end if;

  if v_channel in ('voice','whatsapp','email') then
    v_whych := case when v_policy_ch in ('voice','email','whatsapp')
                    then format('Política de la corrida: grado %s → %s. ', v_grade,
                                case v_policy_ch when 'voice' then 'llamada del agente' when 'email' then 'correo' else 'WhatsApp' end)
                    else '' end
      || format('Historial: contesta %s de %s llamadas. Éxito estimado por su grado: voz %s%%, WhatsApp %s%%.',
           prop->'voice'->>'responses', prop->'voice'->>'attempts',
           round(100 * jnum(prop->'voice'->'success')), round(100 * jnum(prop->'whatsapp'->'success')))
      || case when v_negotiate and v_channel = 'voice' then ' Necesita negociar una alternativa.' else '' end
      || case when v_channel = 'voice' and coalesce(v_pol.email_fallback, true) then ' Si no contesta, recibe un correo.' else '' end;
  end if;

  v_top := v_offers->0->>'name';

  -- Plan
  v_plan := case v_action
    when 'CALL_NOW' then jsonb_build_array(
      jsonb_build_object('step',1,'type','CALL','label','Llamada preventiva del agente'),
      jsonb_build_object('step',2,'type','EMAIL','label','Si no contesta: correo de seguimiento'),
      jsonb_build_object('step',3,'type','UNDERSTAND','label','Identificar su situación'),
      jsonb_build_object('step',4,'type','COMMITMENT','label','Conseguir compromiso de pago'),
      jsonb_build_object('step',5,'type','CONFIRMATION','label','Enviar confirmación y link de pago por correo'),
      jsonb_build_object('step',6,'type','EDUCATION','label', coalesce('Enviar video: ' || (edu->>'title'), 'Enviar video de educación financiera')),
      jsonb_build_object('step',7,'type','FOLLOW_UP','label','Recordatorio antes de la fecha acordada'))
    when 'CALL_ALTERNATIVE_DATE' then jsonb_build_array(
      jsonb_build_object('step',1,'type','CALL','label','Llamada preventiva del agente'),
      jsonb_build_object('step',2,'type','EMAIL','label','Si no contesta: correo de seguimiento'),
      jsonb_build_object('step',3,'type','UNDERSTAND','label','Identificar su situación'),
      jsonb_build_object('step',4,'type','OFFER','label', coalesce('Ofrecer alternativa autorizada: ' || v_top, 'Ofrecer alternativa autorizada')),
      jsonb_build_object('step',5,'type','COMMITMENT','label','Conseguir compromiso concreto'),
      jsonb_build_object('step',6,'type','CONFIRMATION','label','Enviar confirmación y link de pago por correo'),
      jsonb_build_object('step',7,'type','EDUCATION','label', coalesce('Enviar video: ' || (edu->>'title'), 'Enviar video de educación financiera')),
      jsonb_build_object('step',8,'type','FOLLOW_UP','label','Recordatorio antes de la fecha acordada'))
    when 'EMAIL_REMINDER' then jsonb_build_array(
      jsonb_build_object('step',1,'type','EMAIL','label','Correo preventivo con recordatorio y opciones'),
      jsonb_build_object('step',2,'type','EDUCATION','label', coalesce('Video incluido en el correo: ' || (edu->>'title'), 'Video de educación financiera en el correo')),
      jsonb_build_object('step',3,'type','FOLLOW_UP','label','Verificar el pago en la fecha de vencimiento'))
    when 'WHATSAPP' then jsonb_build_array(
      jsonb_build_object('step',1,'type','WHATSAPP','label','Mensaje preventivo con opciones'),
      jsonb_build_object('step',2,'type','COMMITMENT','label','Conseguir compromiso de pago'),
      jsonb_build_object('step',3,'type','EDUCATION','label', coalesce('Enviar video: ' || (edu->>'title'), 'Enviar video de educación financiera')),
      jsonb_build_object('step',4,'type','FOLLOW_UP','label','Recordatorio antes de la fecha acordada'))
    when 'EDUCATION_REMINDER' then jsonb_build_array(
      jsonb_build_object('step',1,'type','EDUCATION','label', coalesce('Enviar video: ' || (edu->>'title'), 'Enviar video de educación financiera')),
      jsonb_build_object('step',2,'type','REMINDER','label','Recordatorio amable 2 días antes del vencimiento'))
    when 'HUMAN' then jsonb_build_array(
      jsonb_build_object('step',1,'type','HUMAN','label','Asignar asesor humano'),
      jsonb_build_object('step',2,'type','FOLLOW_UP','label','Seguimiento del asesor'))
    else '[]'::jsonb end;

  v_succ := case v_channel when 'voice' then jnum(prop->'voice'->'success')
                           when 'whatsapp' then jnum(prop->'whatsapp'->'success')
                           when 'email' then 0.30   -- sin historial de correo: supuesto conservador, etiquetado como estimación
                           when 'human' then 0.5 else 0 end;
  v_prio := round(coalesce(ra.score, 0) * (1 + least(v_amount, 1000) / 1000.0)
                  * (case when coalesce(jnum(f->'days_to_due'), 99) between -15 and 7 then 1.3 else 1 end));

  return jsonb_build_object(
    'customer_id', c.id, 'customer_code', c.customer_code, 'full_name', c.full_name,
    'grade', v_grade, 'ssf_category', v_ssf,
    'risk_score', ra.score, 'risk_band', ra.band, 'probability_default', v_pd,
    'days_to_due', f->'days_to_due', 'days_past_due', f->'days_past_due',
    'action', v_action, 'channel', v_channel,
    'why', v_why, 'why_channel', v_whych,
    'propensity', jsonb_build_object('voice', prop->'voice'->'success', 'whatsapp', prop->'whatsapp'->'success',
                                     'voice_response', prop->'voice'->'response', 'whatsapp_response', prop->'whatsapp'->'response',
                                     'detail', prop),
    'offers', v_offers, 'playbook_key', m->>'playbook_key', 'matched_rules', m->'matched_rules',
    'education', edu, 'plan', v_plan,
    'amount_at_risk', v_amount,
    'expected_success_probability', round(coalesce(v_succ, 0), 3),
    'expected_avoided_amount', round(v_amount * v_pd * coalesce(v_succ, 0), 2),
    'priority', v_prio,
    'contact_enabled', c.contact_enabled,
    'blocked_reason', v_block,
    'financial_profile', to_jsonb(prof));
end $$;

-- ─── Sincronizar pasos del plan (lo usan triggers y el agente) ─────────────
create or replace function sync_plan_step(p_intervention_id uuid, p_step_type text, p_status text,
                                          p_conversation_id uuid default null, p_detail jsonb default '{}',
                                          p_scheduled_for timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_intervention_id is null then return; end if;
  update intervention_steps set
    status          = p_status,
    completed_at    = case when p_status in ('done','skipped','failed') then now() else completed_at end,
    conversation_id = coalesce(p_conversation_id, conversation_id),
    detail          = detail || coalesce(p_detail, '{}'),
    scheduled_for   = coalesce(p_scheduled_for, scheduled_for)
  where id = (select id from intervention_steps
               where intervention_id = p_intervention_id and step_type = p_step_type
                 and status not in ('done','skipped')
               order by step limit 1);
end $$;

create or replace function trg_plan_from_conversation() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_step text;
begin
  if new.intervention_id is null then return new; end if;
  v_step := case new.channel when 'voice' then 'CALL' when 'email' then 'EMAIL' else 'WHATSAPP' end;
  if tg_op = 'INSERT' then
    perform sync_plan_step(new.intervention_id, v_step, 'in_progress', new.id);
  elsif new.status <> old.status and new.status in ('completed','no_answer','failed') then
    perform sync_plan_step(new.intervention_id, v_step,
                           case when new.status = 'completed' then 'done' else 'failed' end, new.id,
                           jsonb_build_object('outcome', new.outcome));
    if new.channel = 'voice' and new.status = 'completed' and new.turn_count > 0 then
      perform sync_plan_step(new.intervention_id, 'EMAIL', 'skipped', new.id, '{"reason":"Contestó la llamada"}');
    end if;
    if new.turn_count > 0 then
      perform sync_plan_step(new.intervention_id, 'UNDERSTAND', 'done', new.id,
                             jsonb_build_object('intent', new.final_intent, 'sentiment', new.sentiment_end));
    end if;
    if new.escalated then
      perform sync_plan_step(new.intervention_id, 'HUMAN', 'in_progress', new.id);
    end if;
  end if;
  return new;
end $$;
create trigger trg_conversations_plan after insert or update of status on conversations
  for each row execute function trg_plan_from_conversation();

create or replace function trg_plan_from_commitment() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_iv uuid := (select intervention_id from conversations where id = new.conversation_id);
begin
  perform sync_plan_step(v_iv, 'OFFER', 'done', new.conversation_id, jsonb_build_object('offer_code', new.offer_code));
  perform sync_plan_step(v_iv, 'COMMITMENT', 'done', new.conversation_id,
                         jsonb_build_object('receipt_code', new.receipt_code, 'amount', new.amount, 'date', new.committed_date));
  -- recordatorio el día anterior a la fecha más lejana del compromiso (saldo, primer pago o fecha), nunca en el pasado
  perform sync_plan_step(v_iv, 'FOLLOW_UP', 'pending', new.conversation_id, '{}',
    greatest(((coalesce((new.params->>'remaining_date')::date, (new.params->>'first_payment_date')::date, new.committed_date, sv_today() + 1) - 1)::timestamp
               + time '09:00') at time zone 'America/El_Salvador',
             now() + interval '1 hour'));
  return new;
end $$;
create trigger trg_commitments_plan after insert on commitments for each row execute function trg_plan_from_commitment();

create or replace function trg_plan_from_handoff() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_iv uuid := (select intervention_id from conversations where id = new.from_conversation_id);
begin
  if new.to_channel = 'whatsapp' and new.action <> 'SEND_EDUCATION' then
    perform sync_plan_step(v_iv, 'WHATSAPP', case when new.status = 'completed' then 'done' else 'in_progress' end,
                           new.from_conversation_id, jsonb_build_object('action', new.action, 'handoff_id', new.id));
  end if;
  return new;
end $$;
create trigger trg_handoffs_plan after insert or update of status on handoffs for each row execute function trg_plan_from_handoff();

create or replace function trg_plan_from_education() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_iv uuid := coalesce(new.intervention_id, (select intervention_id from conversations where id = new.conversation_id));
begin
  perform sync_plan_step(v_iv, 'EDUCATION', case when new.status in ('sent','viewed') then 'done' else 'in_progress' end,
                         new.conversation_id, jsonb_build_object('delivery_id', new.id, 'status', new.status));
  return new;
end $$;
create trigger trg_education_plan after insert or update of status on education_deliveries
  for each row execute function trg_plan_from_education();

-- ─── LA CORRIDA ────────────────────────────────────────────────────────────
-- p_filters: {"grades":["C","D","E"], "max_days_to_due":10, "include_monitor":false, "limit":null}
create or replace function run_prevention(p_filters jsonb default '{}', p_created_by text default 'web')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_run     uuid;
  v_grades  text[] := coalesce(array(select jsonb_array_elements_text(p_filters->'grades')), array['C','D','E']);
  v_maxdays int := coalesce(jnum(p_filters->'max_days_to_due'), 10)::int;
  v_limit   int := jnum(p_filters->'limit')::int;
  cu        record;
  f         jsonb;
  nbi       jsonb;
  v_status  text;
  v_iv      uuid;
  st        jsonb;
  n_eval int := 0; n_req int := 0; n_block int := 0; n_ctrl int := 0;
  v_amount numeric := 0; v_avoid numeric := 0;
begin
  set local statement_timeout = 0;
  insert into prevention_runs (created_by, filters) values (p_created_by, p_filters) returning id into v_run;

  -- las intervenciones programadas de corridas anteriores quedan vencidas: se decide con datos actuales
  update interventions set status = 'expired' where status = 'scheduled' and not is_synthetic;

  for cu in select distinct c.id from customers c join loans l on l.customer_id = c.id and l.status = 'active' loop
    n_eval := n_eval + 1;
    perform compute_risk(cu.id, true, 'prevention_run');
    f   := customer_facts(cu.id);
    continue when jnum(f->'days_to_due') is null or jnum(f->'days_to_due') > v_maxdays or jnum(f->'days_to_due') < -30;
    nbi := next_best_intervention(cu.id, f);
    continue when not ((nbi->>'grade') = any(v_grades));
    continue when nbi->>'action' = 'MONITOR' and nbi->>'blocked_reason' is null and not coalesce(jbool(p_filters->'include_monitor'), false);

    v_status := case when nbi->>'action' = 'BLOCKED' then 'blocked'
                     when nbi->>'action' = 'MONITOR' then 'control_group'
                     else 'scheduled' end;

    insert into interventions (customer_id, loan_id, prevention_run_id, status, priority, risk_score, risk_band, grade, action,
                               next_best, matched_rules, block_reasons, offers, playbook_key, channel_sequence,
                               recommended_channel, reason, amount_at_risk, expected_avoided_amount, scheduled_for)
    values (cu.id, nullif(f->>'loan_id','')::uuid, v_run, v_status, jnum(nbi->'priority')::int, jnum(nbi->'risk_score')::int,
            nbi->>'risk_band', nbi->>'grade', nbi->>'action', nbi, coalesce(nbi->'matched_rules', '[]'),
            case when v_status = 'blocked' then jsonb_build_array(nbi->>'blocked_reason') else '[]'::jsonb end,
            nbi->'offers', nbi->>'playbook_key',
            case when nbi->>'channel' is not null then array[nbi->>'channel'] else '{}'::text[] end,
            nbi->>'channel',
            coalesce(nbi->>'blocked_reason', (select string_agg(x, ' · ') from jsonb_array_elements_text(nbi->'why') x)),
            jnum(nbi->'amount_at_risk'), jnum(nbi->'expected_avoided_amount'), next_contact_slot())
    returning id into v_iv;

    if v_status = 'scheduled' then
      n_req := n_req + 1;
      v_amount := v_amount + coalesce(jnum(nbi->'amount_at_risk'), 0);
      v_avoid  := v_avoid + coalesce(jnum(nbi->'expected_avoided_amount'), 0);
      for st in select * from jsonb_array_elements(nbi->'plan') loop
        insert into intervention_steps (intervention_id, customer_id, step, step_type, label)
        values (v_iv, cu.id, (st->>'step')::int, st->>'type', st->>'label');
      end loop;
    elsif v_status = 'blocked' then n_block := n_block + 1;
    else n_ctrl := n_ctrl + 1; end if;

    exit when v_limit is not null and n_req >= v_limit;
  end loop;

  update prevention_runs set
    customers_evaluated = n_eval, requiring_intervention = n_req, blocked = n_block, control_group = n_ctrl,
    amount_at_risk = v_amount, expected_avoided_amount = v_avoid,
    by_action = (select coalesce(jsonb_object_agg(action, n), '{}') from (select action, count(*) n from interventions where prevention_run_id = v_run group by action) s),
    by_grade  = (select coalesce(jsonb_object_agg(grade, n), '{}') from (select grade, count(*) n from interventions where prevention_run_id = v_run and status = 'scheduled' group by grade) s)
  where id = v_run;

  return (select jsonb_build_object('run_id', r.id, 'customers_evaluated', r.customers_evaluated,
            'requiring_intervention', r.requiring_intervention, 'blocked', r.blocked, 'control_group', r.control_group,
            'by_action', r.by_action, 'by_grade', r.by_grade, 'amount_at_risk', r.amount_at_risk,
            'expected_avoided_amount', r.expected_avoided_amount)
          from prevention_runs r where r.id = v_run);
end $$;

-- Lista para despachar (la usa el servidor de voz)
create or replace function get_prevention_run(p_run_id uuid, p_channel text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'run', to_jsonb(r),
    'policy', (select jsonb_build_object('channel_by_grade', channel_by_grade, 'email_fallback', email_fallback,
                                         'max_calls_per_run', max_calls_per_run,
                                         'max_simulated_calls_per_run', max_simulated_calls_per_run, 'email_from', email_from)
                 from agent_policies where is_active limit 1),
    'interventions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'intervention_id', i.id, 'customer_id', i.customer_id, 'customer_code', c.customer_code, 'full_name', c.full_name,
        'first_name', c.first_name, 'phone_e164', c.phone_e164, 'email', c.email, 'contact_enabled', c.contact_enabled,
        'grade', i.grade, 'action', i.action, 'channel', i.recommended_channel, 'status', i.status,
        'priority', i.priority, 'amount_at_risk', i.amount_at_risk,
        'amount_due_text', fmt_money(i.amount_at_risk), 'due_date', nx.due_date, 'due_date_text', fmt_date_es(nx.due_date),
        'product_name', nx.product_name, 'why', i.next_best->'why', 'offers', i.next_best->'offers',
        'education', i.next_best->'education', 'playbook_key', i.playbook_key)
        order by i.priority desc)
        from interventions i
        join customers c on c.id = i.customer_id
        left join lateral (
          select ins.due_date, l.product_name from loans l
            join installments ins on ins.loan_id = l.id and ins.status in ('pending','partial','overdue')
           where l.id = i.loan_id order by ins.due_date limit 1) nx on true
       where i.prevention_run_id = r.id and i.status = 'scheduled'
         and (p_channel is null or i.recommended_channel = p_channel)), '[]'))
  from prevention_runs r where r.id = p_run_id
$$;

create or replace function mark_run_dispatched(p_run_id uuid, p_summary jsonb) returns void
language sql security definer set search_path = public as $$
  update prevention_runs set status = 'dispatched', dispatched_at = now(), dispatch_summary = p_summary where id = p_run_id
$$;

-- ─── Enviar video ──────────────────────────────────────────────────────────
create or replace function send_education(p_customer_id uuid, p_conversation_id uuid default null, p_slug text default null,
                                          p_reason text default null, p_channel text default 'whatsapp')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e       education_contents;
  v_pick  jsonb;
  v_id    uuid;
  v_url   text;
  v_iv    uuid;
  v_base  text := replace((select payment_link_base_url from agent_policies where is_active limit 1), '/pagar/', '/aprende/');
begin
  if p_slug is not null then
    select * into e from education_contents where slug = p_slug and is_active;
  else
    v_pick := pick_education(p_customer_id);
    select * into e from education_contents where id = (v_pick->>'id')::uuid;
  end if;
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'SIN_VIDEO_APLICABLE'); end if;

  v_iv := coalesce((select intervention_id from conversations where id = p_conversation_id),
                   (select id from interventions where customer_id = p_customer_id and status in ('scheduled','dispatched','completed')
                     and not is_synthetic order by created_at desc limit 1));

  insert into education_deliveries (customer_id, content_id, conversation_id, intervention_id, reason, channel)
  values (p_customer_id, e.id, p_conversation_id, v_iv, p_reason, p_channel) returning id into v_id;
  v_url := v_base || e.slug || '?d=' || v_id;

  -- por correo lo envía el servidor en el mismo mensaje: queda como enviado
  if p_channel = 'email' then
    update education_deliveries set url = v_url, status = 'sent', sent_at = now() where id = v_id;
    return jsonb_build_object('ok', true, 'delivery_id', v_id, 'slug', e.slug, 'title', e.title, 'url', v_url,
                              'duration_s', e.duration_s, 'channel', 'email');
  end if;
  update education_deliveries set url = v_url where id = v_id;

  insert into handoffs (customer_id, from_conversation_id, from_channel, to_channel, action, payload, context_summary)
  values (p_customer_id, p_conversation_id, (select channel from conversations where id = p_conversation_id), 'whatsapp',
          'SEND_EDUCATION', jsonb_build_object('delivery_id', v_id, 'slug', e.slug, 'title', e.title, 'url', v_url,
                                               'duration_s', e.duration_s, 'video_url', e.video_url),
          'Enviar video de educación financiera: ' || e.title);

  if p_conversation_id is not null then
    perform log_event(p_conversation_id, 'education_queued', jsonb_build_object('slug', e.slug, 'delivery_id', v_id));
  end if;
  return jsonb_build_object('ok', true, 'delivery_id', v_id, 'slug', e.slug, 'title', e.title, 'url', v_url);
end $$;

-- Página pública /aprende/[slug]
create or replace function get_education_content(p_slug text, p_delivery_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e education_contents;
begin
  select * into e from education_contents where slug = p_slug and is_active;
  if e.id is null then return jsonb_build_object('found', false); end if;
  if p_delivery_id is not null then
    update education_deliveries set status = 'viewed', viewed_at = coalesce(viewed_at, now())
     where id = p_delivery_id and content_id = e.id;
  end if;
  return jsonb_build_object('found', true, 'slug', e.slug, 'title', e.title, 'description', e.description,
                            'duration_s', e.duration_s, 'video_url', e.video_url, 'script', e.script, 'topic', e.topic);
end $$;

-- ─── Vistas del Centro de Prevención ──────────────────────────────────────
create or replace view v_prevention_center with (security_invoker = true) as
select i.id as intervention_id, i.prevention_run_id, i.customer_id, c.customer_code, c.full_name, c.department,
       c.contact_enabled, i.status, i.grade, i.action, i.recommended_channel as channel, i.priority,
       i.risk_score, jnum(i.next_best->'probability_default') as probability_default,
       i.next_best->>'ssf_category' as ssf_category,
       jnum(i.next_best->'days_to_due')::int as days_to_due, i.amount_at_risk, i.expected_avoided_amount,
       i.next_best->'why'->>0 as why_short, i.next_best->'why' as why, i.next_best->>'why_channel' as why_channel,
       i.next_best->'offers' as offers, i.next_best->'education' as education, i.next_best->>'blocked_reason' as blocked_reason,
       (select count(*) from intervention_steps s where s.intervention_id = i.id) as plan_steps,
       (select count(*) from intervention_steps s where s.intervention_id = i.id and s.status = 'done') as plan_steps_done,
       i.conversation_id, i.created_at
  from interventions i join customers c on c.id = i.customer_id
 where i.prevention_run_id = (select id from prevention_runs order by created_at desc limit 1);

create or replace view v_impact with (security_invoker = true) as
with lr as (select * from prevention_runs order by created_at desc limit 1),
cm as (
  select cm.*, cv.risk_before, cv.is_synthetic, i.amount_due
    from commitments cm
    join conversations cv on cv.id = cm.conversation_id
    left join installments i on i.id = cm.installment_id
)
select
  (select requiring_intervention from lr) as clients_requiring_intervention,
  (select amount_at_risk from lr) as amount_at_risk,
  (select expected_avoided_amount from lr) as expected_avoided_amount_run,
  (select count(distinct customer_id) from conversations where status <> 'active') as clients_intervened,
  (select count(*) from cm) as commitments,
  round(100.0 * (select count(*) from conversations where commitment_id is not null)
        / nullif((select count(*) from conversations cv where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')), 0), 1) as commitment_rate_pct,
  (select coalesce(sum(amount), 0) from cm where status in ('pending','approved','kept')) as amount_committed,
  (select coalesce(sum(amount), 0) from cm where status = 'kept') as amount_kept,
  -- Estimación: monto de la cuota × probabilidad de mora al momento del contacto, para compromisos vigentes o cumplidos
  (select round(coalesce(sum(coalesce(amount_due, amount) * pd_from_score(risk_before)), 0), 2)
     from cm where status in ('pending','approved','kept')) as potential_delinquency_avoided,
  (select count(*) from education_deliveries) as education_sent,
  (select count(*) from education_deliveries where status = 'viewed') as education_viewed,
  (select p95_voice_latency_ms from v_kpis) as p95_voice_latency_ms,
  (select round(avg(cost_usd), 4) from conversations where status = 'completed') as avg_cost_per_intervention_usd,
  true as is_estimate;

create or replace view v_learning with (security_invoker = true) as
select preventive_grade(cv.risk_before) as grade, cv.channel,
  count(*) as conversations,
  count(*) filter (where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) as responded,
  round(100.0 * count(*) filter (where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) / nullif(count(*), 0), 1) as response_rate_pct,
  count(*) filter (where cv.commitment_id is not null) as commitments,
  round(100.0 * count(*) filter (where cv.commitment_id is not null) / nullif(count(*), 0), 1) as commitment_rate_pct,
  round(100.0 * count(cm.id) filter (where cm.status = 'kept') / nullif(count(cm.id) filter (where cm.status in ('kept','broken')), 0), 1) as kept_rate_pct,
  count(*) filter (where cv.escalated) as escalations
from conversations cv
left join commitments cm on cm.id = cv.commitment_id
where cv.status <> 'active' and cv.risk_before is not null
group by 1, 2;

-- ─── Seed del motor (videos + perfiles de voz) ────────────────────────────
create or replace function seed_prevention_config() returns jsonb
language plpgsql as $seed$
begin
  truncate education_deliveries, education_contents restart identity cascade;
  insert into education_contents (slug, title, description, topic, duration_s, script, target_conditions, priority) values
  ('record-crediticio', '¿Por qué importa tu récord crediticio?', 'Qué es el historial y cómo te abre puertas.', 'historial', 20,
   $t$Tu récord crediticio es tu carta de presentación. Pagar a tiempo te ayuda a conseguir mejores tasas y más oportunidades. Un solo atraso puede quedar registrado. Si ves que no llegas a tu fecha, avísanos antes: juntos buscamos una opción.$t$,
   '{"all":[{"fact":"late_payments_12m","op":"gte","value":1}]}', 60),
  ('pagar-tarde', '¿Qué pasa si pagas después de la fecha?', 'Recargos, intereses y récord: lo que cuesta un atraso.', 'atrasos', 18,
   $t$Pagar tarde no solo suma recargos: también afecta tu récord. Programa un recordatorio dos días antes de tu fecha y, si no te alcanza, llámanos antes del vencimiento.$t$,
   '{"all":[{"fact":"late_payments_12m","op":"gte","value":2},{"fact":"days_to_due","op":"between","value":[0,15]}]}', 80),
  ('organizar-cuota', 'Cómo organizar tu pago mensual', 'Separar la cuota el día que recibes tu ingreso.', 'presupuesto', 20,
   $t$El truco es simple: el día que recibes tu ingreso, separa primero el dinero de tu cuota. Anota tus gastos fijos, deja un pequeño colchón y verás que llegar a la fecha es más fácil.$t$,
   '{"any":[{"fact":"partial_payments_6m","op":"gte","value":1},{"fact":"debt_to_income","op":"gte","value":0.3}]}', 70),
  ('fondo-emergencia', 'Tu primer fondo de emergencia', 'Pequeños ahorros para imprevistos.', 'ahorro', 20,
   $t$Un imprevisto no tiene que convertirse en deuda. Empieza con poco: guarda un dólar al día. En tres meses tendrás un colchón para emergencias sin atrasar tus pagos.$t$,
   '{"any":[{"fact":"signals","op":"contains","value":"CUSTOMER_REPORTED_DIFFICULTY"},{"fact":"signals","op":"contains","value":"JOB_LOSS_REPORTED"},{"fact":"signals","op":"contains","value":"ACCOUNT_BALANCE_DROP"}]}', 90),
  ('agro-cosecha', 'Planifica tus pagos con la cosecha', 'Alinear pagos con el ciclo productivo.', 'agro', 20,
   $t$Si tu ingreso llega con la cosecha, planifica desde ahora: separa una parte de cada venta para las cuotas de los meses sin ingreso. Y si el clima afecta tu cultivo, avísanos antes de la fecha.$t$,
   '{"all":[{"fact":"product_type","op":"eq","value":"AGRICOLA_AVIO"}]}', 95),
  ('mantener-historial', '3 consejos para mantener un buen historial', 'Para quien paga bien y quiere seguir así.', 'historial', 15,
   $t$Uno: paga antes de la fecha. Dos: usa recordatorios. Tres: si algo cambia, avísanos a tiempo. Así tu buen historial sigue creciendo.$t$,
   '{"any":[{"fact":"risk_band","op":"in","value":["BAJO","MODERADO"]},{"fact":"kept_commitments_6m","op":"gte","value":1}]}', 40);

  insert into outcome_definitions (code, label, category, counts_as_contact, counts_as_commitment, description, sort_order)
  values ('MESSAGE_SENT', 'Mensaje enviado', 'neutral', false, false, 'Correo o mensaje enviado; sin conversación.', 17)
  on conflict (code) do nothing;

  delete from ai_model_profiles where key in ('voice.elevenlabs', 'telephony.twilio-sv-mobile', 'email.resend');
  insert into ai_model_profiles (key, role, provider, model_id, display_name, modality, params, vad_config, pricing, capabilities,
                                 pricing_source_url, pricing_verified_at, status, notes) values
  ('voice.elevenlabs', 'voice_realtime', 'elevenlabs', 'elevenlabs-agents', 'ElevenLabs Agents + Custom LLM', 'realtime_audio',
   '{"language":"es","llm":"custom","composer_model_key":"composer.gemini-3.1-flash-lite"}', '{}',
   '{"audio_in_per_min":0.08,"note":"USD por minuto de conversación sobre lo incluido en el plan; LLM y telefonía aparte"}',
   '{"telephony":"twilio_native","batch_calling":true,"custom_llm":true,"post_call_webhooks":true,"realtime_server_events":false}',
   'https://elevenlabs.io/pricing/agents', '2026-09-12', 'active',
   $t$Voz, STT, turnos, interrupciones y telefonía. El LLM es nuestro servidor (/v1/chat/completions).$t$),
  ('telephony.twilio-sv-mobile', 'telephony', 'twilio', 'voice-outbound-sv-mobile', 'Twilio saliente a celular SV', 'telephony',
   '{}', '{}', '{"audio_in_per_min":0.29}', '{}', 'https://www.twilio.com/en-us/voice/pricing/sv', '2026-09-12', 'active',
   $t$Costo por minuto de llamada saliente a celular de El Salvador.$t$),
  ('email.resend', 'telephony', 'resend', 'resend-email', 'Resend (correo)', 'telephony', '{}', '{}', '{}', '{}',
   'https://resend.com/pricing', null, 'unverified',
   $t$Correo transaccional. Sin dominio verificado solo permite enviar al correo del dueño de la cuenta (usar onboarding@resend.dev).$t$);

  update agent_policies set default_models = default_models || '{"voice_mode":"elevenlabs","voice_realtime":"voice.elevenlabs"}'
   where is_active;

  return jsonb_build_object('education_contents', (select count(*) from education_contents));
end $seed$;

-- reset_demo ahora incluye el motor y deja una corrida lista
create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $seed$
declare
  v_cfg   jsonb;
  v_pcfg  jsonb;
  v_pers  int;
  v_gen   int;
  v_hist  int;
  v_det   jsonb;
  v_run   jsonb;
  cu      record;
  v_score int;
begin
  set local statement_timeout = 0;

  truncate prevention_runs, intervention_steps, education_deliveries, detection_runs, model_usage, escalations, handoffs,
           payment_links, commitments, conversation_events, turn_evaluations, messages, conversations, interventions,
           risk_assessments, customer_signals, payments, installments, loans, customers restart identity cascade;

  if p_reset_config or not exists (select 1 from agent_policies where is_active) then
    v_cfg := seed_config();
  end if;
  if p_reset_config or not exists (select 1 from education_contents) then
    v_pcfg := seed_prevention_config();
  end if;

  drop table if exists _seed_contacts;
  create temp table _seed_contacts (
    customer_code text, due_date date, profile text, archetype text, channel text,
    kept boolean, days_before int, days_ago int);

  v_pers := seed_personas();
  v_gen  := seed_customers(p_generated_customers);
  v_hist := seed_history();

  for cu in select id, risk_profile_seed from customers loop
    v_score := (compute_risk(cu.id, true, 'seed')->>'score')::int;
    insert into risk_assessments (customer_id, loan_id, score, band, probability_default, factors, trigger, computed_at)
    select cu.id, ra.loan_id, s.sc, risk_band_for(s.sc), pd_from_score(s.sc), '[]', 'seed_backfill', now() - make_interval(days => s.d)
      from (select loan_id from risk_assessments where customer_id = cu.id order by computed_at desc limit 1) ra,
           lateral (values
             (60, greatest(0, least(100, v_score - case when cu.risk_profile_seed in ('ALTO','CRITICO','PREVENTIVO')
                                                        then dint(cu.id::text || '60', 6, 16) else dint(cu.id::text || '60', -4, 4) end))),
             (30, greatest(0, least(100, v_score - case when cu.risk_profile_seed in ('ALTO','CRITICO','PREVENTIVO')
                                                        then dint(cu.id::text || '30', 2, 8) else dint(cu.id::text || '30', -3, 3) end)))
           ) s(d, sc);
  end loop;

  v_det := run_detection();
  -- las intervenciones de la detección clásica se reemplazan por la corrida del motor
  update interventions set status = 'expired' where detection_run_id is not null and status = 'scheduled';
  v_run := run_prevention('{"grades":["B","C","D","E"],"max_days_to_due":10}', 'reset_demo');
  drop table if exists _seed_contacts;

  return jsonb_build_object(
    'ok', true, 'config', v_cfg, 'prevention_config', v_pcfg, 'personas', v_pers, 'generated_customers', v_gen,
    'historical_conversations', v_hist, 'prevention_run', v_run,
    'totals', jsonb_build_object(
      'customers', (select count(*) from customers), 'conversations', (select count(*) from conversations),
      'messages', (select count(*) from messages), 'commitments', (select count(*) from commitments),
      'interventions_scheduled', (select count(*) from interventions where status = 'scheduled'),
      'plan_steps', (select count(*) from intervention_steps), 'education_contents', (select count(*) from education_contents)),
    'next_step', 'Habilita tu número: select set_demo_contact(''DEMO-001'', ''+503XXXXXXXX'');');
end $seed$;

-- ─── Seguridad y realtime de lo nuevo ─────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['education_contents','education_deliveries','prevention_runs','intervention_steps'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', 'read_' || t, t);
  end loop;
  execute 'create policy write_education_contents on public.education_contents for all to authenticated using (true) with check (true)';
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table prevention_runs, intervention_steps, education_deliveries;
  end if;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function get_payment_link(text) to anon;
grant execute on function simulate_payment(text, text) to anon;
grant execute on function get_education_content(text, uuid) to anon;

-- ─── start_conversation: correo protegido + modo simulación ────────────────
-- Cambios vs 0700: (1) el correo también exige contact_enabled en vivo; (2) si la sesión marca
-- app.simulation = on (solo desde start_simulated_conversation) no se exige contact_enabled.
create or replace function start_conversation(
  p_customer_id            uuid,
  p_channel                text,
  p_direction              text    default 'outbound',
  p_external_id            text    default null,
  p_parent_conversation_id uuid    default null,
  p_intervention_id        uuid    default null,
  p_experiment_key         text    default null,
  p_force                  boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c         customers;
  pol       agent_policies := active_policy();
  v_ctx     jsonb;
  v_arm     jsonb;
  v_models  jsonb;
  v_pb      playbooks;
  v_first   text;
  v_iv      uuid;
  v_conv    uuid;
  v_warn    jsonb := '[]';
  v_prompts jsonb;
  v_sim     boolean := coalesce(current_setting('app.simulation', true), '') = 'on';
begin
  select * into c from customers where id = p_customer_id;
  if c.id is null then raise exception 'CLIENTE_NO_EXISTE: %', p_customer_id; end if;

  if p_direction = 'outbound' then
    if pol.live_contact_allowlist_only and p_channel in ('voice','whatsapp','sms','email') and not c.contact_enabled and not v_sim then
      raise exception 'CONTACTO_NO_HABILITADO: % no tiene contact_enabled. Ejecuta set_demo_contact(''%'', ''+503...'').',
        c.customer_code, c.customer_code;
    end if;
    if c.opted_out_at is not null then
      raise exception 'CLIENTE_PIDIO_NO_SER_CONTACTADO: %', c.customer_code;
    end if;
    if c.is_control_group and not p_force then
      raise exception 'GRUPO_DE_CONTROL: % no se contacta (contrafactual). Usa p_force => true solo para pruebas.', c.customer_code;
    end if;
    if (p_channel = 'voice' and not c.consent_voice) or (p_channel = 'whatsapp' and not c.consent_whatsapp)
       or (p_channel = 'email' and not c.consent_email) then
      raise exception 'SIN_CONSENTIMIENTO_PARA_CANAL: %', p_channel;
    end if;
  end if;

  v_ctx := get_conversation_context(p_customer_id);

  if p_direction = 'outbound' and (v_ctx->'rules'->>'blocked')::boolean and not p_force then
    raise exception 'CONTACTO_BLOQUEADO_POR_REGLA: %', v_ctx->'rules'->'block_reasons';
  end if;

  if next_contact_slot() > now() + interval '1 minute' then
    v_warn := v_warn || jsonb_build_array('FUERA_DE_HORARIO_DE_CONTACTO');
  end if;

  if p_experiment_key is not null then
    v_arm := pick_experiment_arm(p_experiment_key, p_customer_id::text);
  end if;
  v_models := resolve_models(v_arm);

  select jsonb_object_agg(key, version) into v_prompts from prompt_versions where is_active;
  if v_arm ? 'prompt_overrides' then v_prompts := coalesce(v_prompts, '{}') || (v_arm->'prompt_overrides'); end if;

  select * into v_pb from playbooks where key = v_ctx->'playbook'->>'key';
  select stage_key into v_first from playbook_stages
   where playbook_id = v_pb.id and not is_terminal order by position limit 1;

  v_iv := coalesce(p_intervention_id,
                   (select id from interventions where customer_id = p_customer_id and status = 'scheduled'
                     order by created_at desc limit 1));

  insert into conversations (customer_id, loan_id, intervention_id, parent_conversation_id, channel, direction,
                             external_id, playbook_id, playbook_key, current_stage, matched_rules, allowed_offers,
                             constraints, tone, context_snapshot, risk_before, experiment_id, arm_key, models,
                             prompt_versions, is_synthetic)
  values (p_customer_id, nullif(v_ctx->'loan'->>'id','')::uuid, v_iv, p_parent_conversation_id, p_channel, p_direction,
          p_external_id, v_pb.id, v_pb.key, v_first, v_ctx->'rules'->'matched', v_ctx->'offers',
          v_ctx->'constraints', v_ctx->'rules'->>'tone', v_ctx, jnum(v_ctx->'risk'->'score'),
          nullif(v_arm->>'experiment_id','')::uuid, v_arm->>'arm_key', v_models, coalesce(v_prompts, '{}'), v_sim)
  returning id into v_conv;

  if v_iv is not null then
    update interventions set status = 'dispatched', dispatched_at = now(), conversation_id = v_conv where id = v_iv;
  end if;

  perform log_event(v_conv, 'conversation_started', jsonb_build_object(
    'channel', p_channel, 'direction', p_direction, 'playbook', v_pb.key, 'first_stage', v_first, 'simulated', v_sim,
    'rules', v_ctx->'rules'->'matched', 'offers', (select jsonb_agg(o->>'code') from jsonb_array_elements(v_ctx->'offers') o),
    'models', v_models, 'arm', v_arm->>'arm_key', 'warnings', v_warn));

  return jsonb_build_object(
    'conversation_id', v_conv,
    'current_stage',   v_first,
    'simulated',       v_sim,
    'models',          v_models,
    'prompt_versions', coalesce(v_prompts, '{}'),
    'experiment',      v_arm,
    'warnings',        v_warn,
    'context',         v_ctx);
end $$;

-- Conversación simulada (sin teléfono/correo real): respeta reglas, bloqueos y grupo de control,
-- pero no exige contact_enabled. Queda marcada is_synthetic = true.
create or replace function start_simulated_conversation(p_customer_id uuid, p_channel text, p_intervention_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  perform set_config('app.simulation', 'on', true);
  begin
    v_res := start_conversation(p_customer_id, p_channel, 'outbound', 'sim-' || substr(gen_random_uuid()::text, 1, 8),
                                null, p_intervention_id);
  exception when others then
    perform set_config('app.simulation', 'off', true);   -- nunca dejar la bandera encendida
    raise;
  end;
  perform set_config('app.simulation', 'off', true);
  return v_res;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function get_payment_link(text) to anon;
grant execute on function simulate_payment(text, text) to anon;
grant execute on function get_education_content(text, uuid) to anon;
