-- ═══════════════════════════════════════════════════════════════════════════
-- 1300 · Guion del banco + resultados del reto (docs/REGLAS-AGENTE-VOZ.md, fase F5)
--   · apply_bank_script(): etapas con el Script de Referencia del banco, persona "Sofía",
--     frases prohibidas contra amenazas. Idempotente.
--   · reset_demo() la vuelve a aplicar cuando reinstala la configuración.
--   · v_conversation_results: las 3 salidas que pide el banco + métricas por conversación.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function apply_bank_script() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_stages int;
begin
  update playbook_stages ps set agent_instructions = s.instr
    from (values
      ('APERTURA', 'Saluda según la hora y preséntate: «Mi nombre es Sofía, asistente digital de Bancoagrícola. ¿Tengo el gusto de hablar con {nombre completo}?». Al confirmar: «Gracias por confirmar.». Antes de confirmar identidad no menciones crédito, montos ni fechas.'),
      ('CONTEXTO', '«El motivo de mi llamada es darle seguimiento a la cuota de su {producto}, que vence el {fecha}. ¿Dispone de unos minutos para conversar?». Si no puede, ofrece llamar en otro momento.'),
      ('DESCUBRIMIENTO', '«Antes de continuar, me gustaría comprender mejor su situación. ¿Cómo se encuentra para realizar ese pago?». Escucha y responde con empatía: «Gracias por explicármelo.» / «Entiendo cómo puede afectar esa situación.». Una pregunta abierta a la vez.'),
      ('PROPUESTA', 'Orientación al acuerdo: «Con base en lo que me comenta, ¿cree que podría realizar el pago durante los próximos días?». Si sí: «Excelente. ¿Qué fecha considera realista para efectuarlo?». Si no: «Comprendo. ¿Existe alguna fecha en la que espere recibir ingresos?». Valida esa fecha antes de decir condiciones.'),
      ('OBJECIONES', 'Negociación respetuosa, sin confrontar ni presionar: «Para asegurar que el acuerdo sea posible de cumplir, ¿qué fecha le resulta más conveniente?». Solo opciones y fechas validadas; máximo 2 contrapropuestas y luego seguimiento con un asesor.'),
      ('COMPROMISO', '«Permítame confirmar lo acordado: usted realizará el pago de {monto} el {fecha}. ¿Es correcto?». Con un sí explícito registra el compromiso de inmediato, sin repetir condiciones.'),
      ('CONFIRMACION', 'Solo con código de recibo: «Perfecto. Gracias por su compromiso.». Ofrece enviar por correo la confirmación con el enlace de pago.'),
      ('SIGUIENTE_PASO', 'Confirma el envío de la confirmación y el enlace de pago, y pasa al cierre.'),
      ('CIERRE', '«Agradezco mucho su tiempo y disposición para conversar. Ha sido un gusto atenderle. Le deseo un excelente día.»')
    ) as s(stage_key, instr)
   where ps.stage_key = s.stage_key;
  get diagnostics v_stages = row_count;

  update agent_policies set
    assistant_name     = 'Sofía, asistente digital de Bancoagrícola',
    disclosure_text    = 'Mi nombre es Sofía, asistente digital de Bancoagrícola.',
    prohibited_phrases = array(select distinct unnest(prohibited_phrases || array[
      'embargo', 'demanda', 'juicio', 'abogados', 'cárcel', 'policía', 'lista negra', 'boletinar',
      'visitaremos su casa', 'hablaremos con su familia', 'hablaremos con su empleador', 'consecuencias legales']))
   where is_active;

  return jsonb_build_object('stages_updated', v_stages, 'assistant_name', (select assistant_name from agent_policies where is_active limit 1));
end $$;

-- reset_demo() conserva su lógica y aplica el guion del banco al reinstalar la configuración
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'reset_demo_base') then
    alter function reset_demo(boolean, int) rename to reset_demo_base;
  end if;
end $$;

create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  v_res := reset_demo_base(p_reset_config, p_generated_customers);
  if p_reset_config then
    v_res := v_res || jsonb_build_object('bank_script', apply_bank_script());
  end if;
  return v_res;
end $$;

-- ─── Resultados en los términos del banco ─────────────────────────────────
-- FECHA_ACORDADA · SEGUIMIENTO · SIN_ACUERDO (+ SIN_RESULTADO para no contestó / falla)
create or replace view v_conversation_results with (security_invoker = true) as
select c.id as conversation_id, c.customer_id, cu.customer_code, cu.full_name, c.channel, c.is_synthetic,
       c.started_at, c.ended_at, extract(epoch from (c.ended_at - c.started_at))::int as duration_s,
       c.outcome, od.label as outcome_label,
       case
         when c.commitment_id is not null or coalesce(od.counts_as_commitment, false) then 'FECHA_ACORDADA'
         when c.outcome in ('FOLLOW_UP_REQUIRED', 'CALLBACK_SCHEDULED', 'HUMAN_ESCALATION', 'PENDING_APPROVAL', 'ALREADY_PAID') then 'SEGUIMIENTO'
         when c.outcome in ('EXPLICIT_REFUSAL', 'DO_NOT_CONTACT', 'WRONG_PERSON') then 'SIN_ACUERDO'
         when c.ended_at is null then 'EN_CURSO'
         else 'SIN_RESULTADO'
       end as bank_result,
       cm.receipt_code, cm.committed_date, cm.amount as committed_amount, cm.status as commitment_status,
       c.turn_count, c.interruption_count,
       lat.avg_latency_ms, lat.p95_latency_ms, lat.turns_under_2s_pct,
       (select count(*) from conversation_events e where e.conversation_id = c.id and e.event_type = 'guardrail_triggered')::int as guardrail_events,
       c.summary
  from conversations c
  join customers cu on cu.id = c.customer_id
  left join outcome_definitions od on od.code = c.outcome
  left join commitments cm on cm.id = c.commitment_id
  left join lateral (
    select round(avg(m.latency_ms))::int as avg_latency_ms,
           round(percentile_cont(0.95) within group (order by m.latency_ms))::int as p95_latency_ms,
           round(100.0 * count(*) filter (where m.latency_ms < 2000) / nullif(count(*), 0))::int as turns_under_2s_pct
      from messages m
     where m.conversation_id = c.id and m.role = 'agent' and m.latency_ms >= 0
  ) lat on true;

grant select on v_conversation_results to authenticated, service_role;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function get_payment_link(text) to anon;
grant execute on function simulate_payment(text, text) to anon;
grant execute on function get_education_content(text, uuid) to anon;

select apply_bank_script();
