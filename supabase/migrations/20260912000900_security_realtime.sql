-- ═══════════════════════════════════════════════════════════════════════════
-- 0900 · Seguridad (RLS) + Realtime
--
--   service_role (secret key, SOLO en servidores de voz/WhatsApp) → todo
--   authenticated (web con login)  → lee todo, edita configuración, llama RPCs
--   anon (página pública de pago)  → solo get_payment_link / simulate_payment
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare
  t text;
  config_tables text[] := array['offers','collection_rules','rule_offers','playbooks','playbook_stages',
                                'evaluation_criteria','agent_policies','rule_fact_definitions','outcome_definitions',
                                'signal_definitions','ai_model_profiles','prompt_versions','experiments',
                                'experiment_arms','eval_scenarios'];
  all_tables text[];
begin
  select array_agg(tablename) into all_tables from pg_tables where schemaname = 'public';
  foreach t in array all_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', 'read_' || t, t);
    if t = any(config_tables) then
      execute format('create policy %I on public.%I for all to authenticated using (true) with check (true)', 'write_' || t, t);
    end if;
  end loop;
end $$;

-- Escalaciones: la web las atiende (asignar, resolver)
create policy update_escalations on escalations for update to authenticated using (true) with check (true);
-- Compromisos: la web aprueba los que requieren aprobación
create policy update_commitments on commitments for update to authenticated using (true) with check (true);
-- Clientes: la web puede editar datos de contacto demo
create policy update_customers on customers for update to authenticated using (true) with check (true);

-- Funciones: nada público por defecto
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function get_payment_link(text) to anon;
grant execute on function simulate_payment(text, text) to anon;

-- Realtime: lo que el dashboard escucha en vivo
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      conversations, messages, turn_evaluations, conversation_events, interventions,
      commitments, handoffs, escalations, payment_links, detection_runs;
  end if;
end $$;
