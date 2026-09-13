-- @@ reset
select (reset_demo())->'bank_script' as guion;
-- @@ tabla
create temp table _t (n serial, paso text, ok boolean, detalle text);
-- @@ guion del banco y resultados
do $$
declare r jsonb; n int; s text;
begin
  select count(*) into n from playbook_stages where stage_key = 'COMPROMISO' and agent_instructions like '%Permítame confirmar lo acordado%';
  insert into _t(paso,ok,detalle) values ('etapas con frase de confirmación del banco', n = (select count(*) from playbooks), n::text);
  select agent_instructions into s from playbook_stages where stage_key = 'APERTURA' limit 1;
  insert into _t(paso,ok,detalle) values ('apertura con Sofía y verificación', s like '%Sofía%' and s like '%¿Tengo el gusto de hablar con%', left(s, 90));
  select assistant_name into s from agent_policies where is_active;
  insert into _t(paso,ok,detalle) values ('persona Sofía en la política', s = 'Sofía, asistente digital de Bancoagrícola', s);
  insert into _t(paso,ok,detalle) values ('frases de amenaza prohibidas', (select 'embargo' = any(prohibited_phrases) and 'consecuencias legales' = any(prohibited_phrases) from agent_policies where is_active), null);
  insert into _t(paso,ok,detalle) values ('apply_bank_script idempotente', (select count(*) from agent_policies, unnest(prohibited_phrases) p where is_active and p = 'embargo') = 1
    and (apply_bank_script()->>'stages_updated')::int > 0 and (select count(*) from agent_policies, unnest(prohibited_phrases) p where is_active and p = 'embargo') = 1, null);

  insert into _t(paso,ok,detalle) values ('v_conversation_results solo categorías del banco',
    not exists (select 1 from v_conversation_results where bank_result not in ('FECHA_ACORDADA','SEGUIMIENTO','SIN_ACUERDO','SIN_RESULTADO','EN_CURSO')),
    (select string_agg(bank_result || '=' || k, ' ') from (select bank_result, count(*) k from v_conversation_results group by 1) x));
  insert into _t(paso,ok,detalle) values ('compromiso → FECHA_ACORDADA con recibo',
    exists (select 1 from v_conversation_results where bank_result = 'FECHA_ACORDADA' and receipt_code is not null),
    (select receipt_code from v_conversation_results where bank_result = 'FECHA_ACORDADA' and receipt_code is not null limit 1));
  insert into _t(paso,ok,detalle) values ('negativa → SIN_ACUERDO',
    not exists (select 1 from v_conversation_results where outcome = 'EXPLICIT_REFUSAL' and bank_result <> 'SIN_ACUERDO'), null);

  update playbook_stages set agent_instructions = 'EDITADO POR VENTAS' where stage_key = 'CIERRE';
  perform reset_demo(false);
  insert into _t(paso,ok,detalle) values ('reset_demo(false) respeta ediciones de ventas',
    exists (select 1 from playbook_stages where stage_key = 'CIERRE' and agent_instructions = 'EDITADO POR VENTAS'), null);
end $$;
-- @@ RESULTADOS
select n, case when ok then '✅' else '❌' end as r, paso, left(detalle, 120) detalle from _t order by n;
