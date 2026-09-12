-- @@ reset
select (reset_demo())->'totals' t;
-- @@ detección
select customers_evaluated, scheduled, blocked, control_group, no_action from detection_runs;
-- @@ distribución
select * from v_risk_distribution order by avg_score;
-- @@ personajes
select customer_code, risk_score, risk_band, days_to_due, intervention_status from v_customer_overview where is_demo_persona order by 1;
-- @@ impacto
select * from v_prevention_impact;
-- @@ canales
select channel, conversations, response_rate_pct, commitment_rate_pct, kept_rate_pct, escalations, avg_cost_usd from v_channel_performance;
-- @@ kpis clave
select customers_at_risk, interventions_scheduled, response_rate_pct, commitment_rate_pct, commitment_kept_rate_pct, escalations_open, p95_voice_latency_ms, voice_interruption_rate_pct, avg_cost_per_conversation_usd from v_kpis;
-- @@ ofertas
select offer_code, times_accepted, kept, broken from v_offer_performance order by times_accepted desc;
