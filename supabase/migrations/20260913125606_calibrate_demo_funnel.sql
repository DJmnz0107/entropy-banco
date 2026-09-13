-- ═══════════════════════════════════════════════════════════════════════════
-- 1400 · Calibración del embudo de demo (datos 100% ficticios, ver CLAUDE.md).
--   El seed ya es aleatorio determinista; esto sube un poco el desenlace
--   (más contestaron, más compromiso, más cumplieron) sobre los MISMOS
--   registros, sin inventar llamadas nuevas ni tocar el mecanismo real.
--   Se calcula como % de las llamadas de voz existentes, así que es estable
--   sin importar cuántas genere seed_customers()/seed_history() cada vez.
--   reset_demo() la aplica automáticamente al final.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function seed_calibrate_demo_funnel() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_calls            int;
  v_kept             int;
  v_kept_target      int;
  v_kept_need        int;
  v_answered         int;
  v_answered_target  int;
  v_answered_need    int;
  v_committed        int;
  v_committed_target int;
  v_committed_need   int;
  v_flip             record;
  v_inst             installments;
  v_amt              numeric;
  v_recibo           text;
begin
  select count(*) into v_calls from conversations where channel = 'voice' and outcome is not null;
  if v_calls = 0 then return jsonb_build_object('skipped', true); end if;

  -- 1) "Cumplieron" ~35 de cada 100: promesas ya vencidas de llamadas de voz pasan de 'broken' a 'kept'.
  select count(*) into v_kept from commitments cm join conversations cv on cv.id = cm.conversation_id
   where cv.channel = 'voice' and cm.status = 'kept';
  v_kept_target := round(v_calls * 0.35);
  v_kept_need := greatest(0, v_kept_target - v_kept);
  if v_kept_need > 0 then
    update commitments set status = 'kept', resolved_at = coalesce(resolved_at, committed_date::timestamptz + interval '2 days')
     where id in (
       select cm.id from commitments cm join conversations cv on cv.id = cm.conversation_id
        where cv.channel = 'voice' and cm.status = 'broken'
        order by cm.committed_date desc limit v_kept_need
     );
  end if;

  -- 2) "Contestaron" ~84 de cada 100: algunas llamadas sin respuesta terminan agendando otra llamada.
  select count(*) into v_answered from conversations cv join outcome_definitions od on od.code = cv.outcome
   where cv.channel = 'voice' and od.counts_as_contact;
  v_answered_target := round(v_calls * 0.84);
  v_answered_need := greatest(0, v_answered_target - v_answered);
  if v_answered_need > 0 then
    update conversations set outcome = 'CALLBACK_SCHEDULED'
     where id in (
       select id from conversations where channel = 'voice' and outcome = 'NO_ANSWER'
        order by started_at desc limit v_answered_need
     );
  end if;

  -- 3) "Llegaron a compromiso" ~52 de cada 100: un seguimiento se convierte en pago parcial acordado,
  --    con su compromiso real (mismo principio que registrar_commitment: sin recibo no cuenta).
  select count(*) into v_committed from conversations cv join outcome_definitions od on od.code = cv.outcome
   where cv.channel = 'voice' and od.counts_as_commitment;
  v_committed_target := round(v_calls * 0.52);
  v_committed_need := greatest(0, v_committed_target - v_committed);
  if v_committed_need > 0 then
    for v_flip in
      select id, customer_id, loan_id from conversations
       where channel = 'voice' and outcome = 'FOLLOW_UP_REQUIRED'
       order by started_at desc limit v_committed_need
    loop
      select * into v_inst from installments
       where loan_id = v_flip.loan_id and status in ('pending', 'partial', 'overdue')
       order by due_date limit 1;
      continue when v_inst.id is null;
      v_amt := round(v_inst.amount_due * 0.5, 2);
      v_recibo := 'CMP-' || upper(substr(md5(v_flip.id::text || 'calib'), 1, 6));
      update conversations set outcome = 'PARTIAL_PAYMENT_AGREED' where id = v_flip.id;
      insert into commitments (conversation_id, customer_id, loan_id, installment_id, offer_code, commitment_type,
                               amount, committed_date, original_due_date, params, terms_text, status,
                               requires_approval, customer_confirmed, policy_validated, receipt_code, is_synthetic)
      values (v_flip.id, v_flip.customer_id, v_flip.loan_id, v_inst.id, 'PAGO_PARCIAL_50', 'PARTIAL_PAYMENT',
              v_amt, v_inst.due_date + 7, v_inst.due_date, jsonb_build_object('amount', v_amt, 'date', v_inst.due_date + 7),
              'Pago parcial de ' || fmt_money(v_amt) || ' el ' || fmt_date_es(v_inst.due_date + 7), 'pending',
              false, true, true, v_recibo, true);
    end loop;
  end if;

  return jsonb_build_object('calls', v_calls, 'kept_flipped', v_kept_need, 'answered_flipped', v_answered_need, 'committed_flipped', v_committed_need);
end $$;

-- reset_demo() aplica la calibración al final, igual que ya hace con apply_bank_script()
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'reset_demo_pre_funnel_calibration') then
    alter function reset_demo(boolean, int) rename to reset_demo_pre_funnel_calibration;
  end if;
end $$;

create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  v_res := reset_demo_pre_funnel_calibration(p_reset_config, p_generated_customers);
  v_res := v_res || jsonb_build_object('funnel_calibration', seed_calibrate_demo_funnel());
  return v_res;
end $$;

-- Aplica también a la base ya instalada (sin volver a correr reset_demo, para no borrar nada de hoy)
select seed_calibrate_demo_funnel();
