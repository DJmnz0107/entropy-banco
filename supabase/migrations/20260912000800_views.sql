-- ═══════════════════════════════════════════════════════════════════════════
-- 0800 · Vistas para el dashboard (el equipo web consulta esto, no tablas crudas)
-- security_invoker: respetan RLS del usuario que consulta.
-- ═══════════════════════════════════════════════════════════════════════════

-- Último riesgo por cliente
create or replace view v_latest_risk with (security_invoker = true) as
select distinct on (customer_id) customer_id, id as risk_assessment_id, score, band, probability_default, factors, computed_at
  from risk_assessments
 order by customer_id, computed_at desc;

-- Ficha de cliente / cola de riesgo
create or replace view v_customer_overview with (security_invoker = true) as
select
  c.id as customer_id, c.customer_code, c.full_name, c.first_name, c.segment, c.department, c.city,
  c.income_type, c.preferred_channel, c.is_control_group, c.contact_enabled, c.is_demo_persona,
  c.opted_out_at is not null as opted_out, c.demo_notes,
  f.loan_id, f.product_type, f.balance, f.amount_due, f.next_due_date, f.days_to_due, f.days_past_due,
  r.score as risk_score, r.band as risk_band, r.probability_default,
  (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(r.factors) x
     where (x->>'points')::numeric > 0 limit 3) s) as top_factors,
  (select coalesce(array_agg(distinct cs.signal_type), '{}') from customer_signals cs
     where cs.customer_id = c.id and cs.is_active) as active_signals,
  lc.started_at as last_contact_at, lc.channel as last_contact_channel, lc.outcome as last_outcome,
  (select i.status from interventions i where i.customer_id = c.id order by i.created_at desc limit 1) as intervention_status,
  (select count(*) from commitments cm where cm.customer_id = c.id and cm.status in ('pending','pending_approval','approved')) as open_commitments
from customers c
left join v_latest_risk r on r.customer_id = c.id
left join lateral (
  select l.id as loan_id, l.product_type, l.balance, i.amount_due - i.amount_paid as amount_due, i.due_date as next_due_date,
         i.due_date - sv_today() as days_to_due, greatest(0, sv_today() - i.due_date) as days_past_due
    from loans l join installments i on i.loan_id = l.id and i.status in ('pending','partial','overdue')
   where l.customer_id = c.id and l.status = 'active'
   order by i.due_date limit 1
) f on true
left join lateral (
  select cv.started_at, cv.channel, cv.outcome from conversations cv
   where cv.customer_id = c.id order by cv.started_at desc limit 1
) lc on true;

-- Llamadas/chats EN VIVO (Supabase Realtime sobre conversations + messages)
create or replace view v_live_conversations with (security_invoker = true) as
select
  cv.id as conversation_id, cv.channel, cv.direction, cv.started_at,
  extract(epoch from now() - cv.started_at)::int as seconds_elapsed,
  c.customer_code, c.full_name, cv.playbook_key, cv.current_stage, ps.name as current_stage_name,
  cv.turn_count, cv.sentiment_start, cv.sentiment_end, cv.interruption_count, cv.refusal_count,
  cv.terms_interrupted, cv.escalated, cv.risk_before, cv.matched_rules, cv.allowed_offers, cv.models,
  lm.role as last_message_role, lm.content as last_message, lm.created_at as last_message_at,
  le.pace as current_pace, le.decision as last_decision, le.rule_label as last_rule, le.intent as last_intent
from conversations cv
join customers c on c.id = cv.customer_id
left join playbook_stages ps on ps.playbook_id = cv.playbook_id and ps.stage_key = cv.current_stage
left join lateral (select role, content, created_at from messages m where m.conversation_id = cv.id order by seq desc limit 1) lm on true
left join lateral (select pace, decision, rule_label, intent from turn_evaluations t where t.conversation_id = cv.id order by seq desc limit 1) le on true
where cv.status = 'active';

-- Línea de tiempo reconstruible de una conversación
create or replace view v_conversation_timeline with (security_invoker = true) as
select m.conversation_id, m.created_at as at, 'message' as kind, m.role, m.stage_key,
       m.content as title, m.heard_text as detail,
       jsonb_build_object('seq', m.seq, 'latency_ms', m.latency_ms, 'interrupted', m.interrupted,
                          'played_ms', m.played_ms, 'audio_ms', m.audio_ms, 'is_backchannel', m.is_backchannel,
                          'modality', m.input_modality) as data
  from messages m
union all
select t.conversation_id, t.created_at, 'evaluation', 'system', t.stage_key,
       coalesce(t.intent, '') || ' · ' || coalesce(t.sentiment, '') || ' → ' || t.decision ||
         case when t.from_stage <> t.to_stage then ' (' || t.from_stage || ' → ' || t.to_stage || ')' else '' end,
       t.rule_label,
       jsonb_build_object('seq', t.seq, 'scorecard', t.scorecard, 'pace', t.pace, 'rule_id', t.rule_id,
                          'control_message', t.control_message)
  from turn_evaluations t
union all
select e.conversation_id, e.created_at, 'event', 'system', e.stage_key, e.event_type, e.severity, e.payload
  from conversation_events e where e.conversation_id is not null;

-- KPIs principales (una fila)
create or replace view v_kpis with (security_invoker = true) as
with conv as (
  select cv.*, exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer') as responded
    from conversations cv where cv.started_at >= now() - interval '45 days'
), agent_msgs as (
  select m.latency_ms, m.interrupted, cv.channel from messages m join conversations cv on cv.id = m.conversation_id
   where m.role = 'agent' and m.created_at >= now() - interval '45 days'
)
select
  (select count(*) from customers) as customers_total,
  (select count(*) from v_latest_risk where band in ('PREVENTIVO','ALTO','CRITICO')) as customers_at_risk,
  (select count(*) from interventions where status = 'scheduled') as interventions_scheduled,
  (select count(*) from conversations where status = 'active') as conversations_live,
  (select count(*) from conv) as conversations_45d,
  (select count(distinct customer_id) from conv where responded) as customers_contacted,
  round(100.0 * (select count(*) from conv where responded) / nullif((select count(*) from conv), 0), 1) as response_rate_pct,
  (select count(*) from commitments where created_at >= now() - interval '45 days') as commitments_45d,
  round(100.0 * (select count(*) from conv where commitment_id is not null)
        / nullif((select count(*) from conv where responded), 0), 1) as commitment_rate_pct,
  round(100.0 * (select count(*) from commitments where status = 'kept')
        / nullif((select count(*) from commitments where status in ('kept','broken')), 0), 1) as commitment_kept_rate_pct,
  (select coalesce(sum(amount), 0) from payments where channel = 'link_pago' and paid_at >= now() - interval '45 days') as paid_via_links_usd,
  (select count(*) from escalations where status <> 'resolved') as escalations_open,
  round(100.0 * (select count(*) from conv where escalated) / nullif((select count(*) from conv where responded), 0), 1) as escalation_rate_pct,
  (select avg(latency_ms)::int from agent_msgs where latency_ms is not null) as avg_latency_ms,
  (select (percentile_cont(0.95) within group (order by latency_ms))::int from agent_msgs where channel = 'voice' and latency_ms is not null) as p95_voice_latency_ms,
  round(100.0 * (select count(*) from agent_msgs where channel = 'voice' and interrupted)
        / nullif((select count(*) from agent_msgs where channel = 'voice'), 0), 1) as voice_interruption_rate_pct,
  round((select avg(cost_usd) from conv where status = 'completed'), 4) as avg_cost_per_conversation_usd,
  round(100.0 * (select count(*) from conv where sentiment_end in ('POSITIVE','NEUTRAL'))
        / nullif((select count(*) from conv where sentiment_end is not null), 0), 1) as positive_or_neutral_end_pct,
  (select count(*) from conv where status = 'failed') + (select count(*) from conversation_events where severity = 'error'
     and created_at >= now() - interval '45 days') as failed_interactions,
  (select count(*) from customers where is_control_group) as control_group_size;

-- Impacto preventivo: intervenidos vs grupo de control
-- ⚠️ Con datos sintéticos esta diferencia es ILUSTRATIVA (fue generada así). No presentarla como evidencia.
create or replace view v_prevention_impact with (security_invoker = true) as
with at_risk as (
  select c.id, c.is_control_group from customers c
    join v_latest_risk r on r.customer_id = c.id
   where c.risk_profile_seed in ('PREVENTIVO','ALTO','CRITICO') or r.band in ('PREVENTIVO','ALTO','CRITICO')
), inst as (
  select ar.is_control_group, i.id, i.days_late, i.status,
         exists (select 1 from conversations cv where cv.customer_id = ar.id
                   and cv.started_at::date between i.due_date - 10 and i.due_date
                   and exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) as treated,
         exists (select 1 from commitments cm where cm.installment_id = i.id and cm.status = 'kept') as commitment_kept
    from at_risk ar
    join loans l on l.customer_id = ar.id
    join installments i on i.loan_id = l.id
   where i.due_date between sv_today() - 45 and sv_today() - 1
)
select
  case when is_control_group then 'grupo_control' when treated then 'intervenido' else 'no_contactado' end as cohort,
  count(*) as installments,
  count(*) filter (where days_late = 0 or commitment_kept) as on_time_or_commitment_kept,
  count(*) filter (where days_late > 0 and not commitment_kept or status = 'overdue') as late,
  round(100.0 * count(*) filter (where days_late > 0 and not commitment_kept or status = 'overdue') / nullif(count(*), 0), 1) as late_rate_pct
from inst
group by 1;

-- Rendimiento por canal
create or replace view v_channel_performance with (security_invoker = true) as
select cv.channel,
  count(*) as conversations,
  count(*) filter (where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) as responded,
  round(100.0 * count(*) filter (where exists (select 1 from messages m where m.conversation_id = cv.id and m.role = 'customer')) / nullif(count(*), 0), 1) as response_rate_pct,
  count(*) filter (where cv.commitment_id is not null) as commitments,
  round(100.0 * count(*) filter (where cv.commitment_id is not null) / nullif(count(*), 0), 1) as commitment_rate_pct,
  round(100.0 * count(*) filter (where cm.status = 'kept') / nullif(count(*) filter (where cm.status in ('kept','broken')), 0), 1) as kept_rate_pct,
  count(*) filter (where cv.escalated) as escalations,
  (avg(cv.duration_ms) / 1000)::int as avg_duration_s,
  avg(cv.avg_latency_ms)::int as avg_latency_ms,
  round(avg(cv.cost_usd), 4) as avg_cost_usd
from conversations cv
left join commitments cm on cm.id = cv.commitment_id
where cv.status <> 'active'
group by cv.channel;

-- ¿Qué regla funciona mejor? (feedback para quien configura)
create or replace view v_rule_performance with (security_invoker = true) as
select r->>'key' as rule_key, r->>'name' as rule_name,
  count(*) as conversations,
  count(*) filter (where cv.commitment_id is not null) as commitments,
  round(100.0 * count(*) filter (where cv.commitment_id is not null) / nullif(count(*), 0), 1) as commitment_rate_pct,
  round(100.0 * count(*) filter (where cm.status = 'kept') / nullif(count(*) filter (where cm.status in ('kept','broken')), 0), 1) as kept_rate_pct,
  round(100.0 * count(*) filter (where cv.escalated) / nullif(count(*), 0), 1) as escalation_rate_pct,
  round(avg(cv.risk_before - cv.risk_after), 1) as avg_risk_reduction
from conversations cv
cross join lateral jsonb_array_elements(cv.matched_rules) r
left join commitments cm on cm.id = cv.commitment_id
where cv.status <> 'active'
group by 1, 2;

-- ¿Qué oferta se acepta y se cumple?
create or replace view v_offer_performance with (security_invoker = true) as
select o.code as offer_code, o.name as offer_name, o.offer_type,
  (select count(*) from conversations cv where cv.allowed_offers @> jsonb_build_array(jsonb_build_object('code', o.code))) as times_allowed,
  count(cm.id) as times_accepted,
  count(cm.id) filter (where cm.status = 'kept') as kept,
  count(cm.id) filter (where cm.status = 'broken') as broken,
  round(100.0 * count(cm.id) filter (where cm.status = 'kept') / nullif(count(cm.id) filter (where cm.status in ('kept','broken')), 0), 1) as kept_rate_pct,
  coalesce(sum(cm.amount), 0) as amount_committed
from offers o
left join commitments cm on cm.offer_code = o.code
group by o.code, o.name, o.offer_type;

-- Embudo por etapa + dónde interrumpen (para iterar guiones)
create or replace view v_stage_funnel with (security_invoker = true) as
select cv.playbook_key, m.stage_key,
  min(ps.position) as position,
  count(distinct cv.id) as conversations_reached,
  count(*) filter (where m.role = 'agent') as agent_turns,
  count(*) filter (where m.role = 'agent' and m.interrupted) as interruptions,
  round(100.0 * count(*) filter (where m.role = 'agent' and m.interrupted) / nullif(count(*) filter (where m.role = 'agent'), 0), 1) as interruption_rate_pct,
  avg(m.latency_ms) filter (where m.role = 'agent')::int as avg_latency_ms
from messages m
join conversations cv on cv.id = m.conversation_id
left join playbook_stages ps on ps.playbook_id = cv.playbook_id and ps.stage_key = m.stage_key
group by cv.playbook_key, m.stage_key;

-- Laboratorio: comparación de modelos
create or replace view v_model_performance with (security_invoker = true) as
select mu.model_profile_key, mp.display_name, mp.role, mp.provider, mp.status, mp.pricing_verified_at,
  count(distinct mu.conversation_id) as conversations,
  avg(mu.latency_ms)::int as avg_latency_ms,
  (percentile_cont(0.95) within group (order by mu.latency_ms))::int as p95_latency_ms,
  round(sum(mu.cost_usd) / nullif(count(distinct mu.conversation_id), 0), 5) as cost_per_conversation_usd,
  round(100.0 * count(distinct mu.conversation_id) filter (where cv.commitment_id is not null)
        / nullif(count(distinct mu.conversation_id), 0), 1) as commitment_rate_pct,
  round(avg(cv.interruption_count)::numeric, 2) as avg_interruptions,
  round(avg(cv.false_barge_in_count)::numeric, 2) as avg_false_barge_ins,
  bool_or(cv.is_synthetic) as includes_synthetic_data
from model_usage mu
join ai_model_profiles mp on mp.key = mu.model_profile_key
left join conversations cv on cv.id = mu.conversation_id
group by mu.model_profile_key, mp.display_name, mp.role, mp.provider, mp.status, mp.pricing_verified_at;

-- Serie diaria (hora SV)
create or replace view v_daily_metrics with (security_invoker = true) as
select (cv.started_at at time zone 'America/El_Salvador')::date as day,
  count(*) as conversations,
  count(*) filter (where cv.commitment_id is not null) as commitments,
  count(*) filter (where cv.escalated) as escalations,
  count(*) filter (where cv.outcome = 'NO_ANSWER') as no_answer,
  avg(cv.avg_latency_ms)::int as avg_latency_ms,
  round(sum(cv.cost_usd), 4) as cost_usd
from conversations cv
group by 1;

create or replace view v_risk_distribution with (security_invoker = true) as
select band, count(*) as customers, round(avg(score), 1) as avg_score
  from v_latest_risk group by band;

create or replace view v_sentiment_shift with (security_invoker = true) as
select sentiment_start, sentiment_end, count(*) as conversations
  from conversations where sentiment_start is not null and sentiment_end is not null
 group by 1, 2;
