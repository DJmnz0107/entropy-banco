-- ═══════════════════════════════════════════════════════════════════════════
-- 1700 · Ajustes de voz: temperatura documentada + más turnos para llegar al
--   siguiente paso.
--   · CLAUDE.md dice "Voz realtime: 0.4 (a medir), techo 0.5" — el composer de
--     voz seguía heredando el 0.3 de WhatsApp, más rígido/repetitivo.
--   · max_turns_per_conversation (16) se agotaba antes de llegar a la etapa
--     SIGUIENTE_PASO (el ofrecimiento de WhatsApp) cuando la llamada tenía
--     algún turno de más (una validación sin fecha, una repetición). Se sube
--     a 24 para dejar margen real sin alargar la llamada indefinidamente.
--   reset_demo() reaplica ambos al final (mismo patrón que 1300/1400/1500),
--   porque seed_config() reinstala agent_policies/ai_model_profiles con los
--   valores originales.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function apply_voice_temperature() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_count int;
  v_turns int;
begin
  update ai_model_profiles
     set params = jsonb_set(params, '{temperature}', '0.4')
   where key in ('composer.gemini-3.1-flash-lite', 'composer.gemini-3.5-flash');
  get diagnostics v_count = row_count;

  update agent_policies set max_turns_per_conversation = 24 where is_active and max_turns_per_conversation < 24;
  get diagnostics v_turns = row_count;

  return jsonb_build_object('composer_profiles_updated', v_count, 'policies_turns_raised', v_turns);
end $$;

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'reset_demo_pre_voice_temperature') then
    alter function reset_demo(boolean, int) rename to reset_demo_pre_voice_temperature;
  end if;
end $$;

create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  v_res := reset_demo_pre_voice_temperature(p_reset_config, p_generated_customers);
  if p_reset_config then
    v_res := v_res || jsonb_build_object('voice_temperature', apply_voice_temperature());
  end if;
  return v_res;
end $$;

select apply_voice_temperature();
