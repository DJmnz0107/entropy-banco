-- ═══════════════════════════════════════════════════════════════════════════
-- 1500 · Handoff proactivo Voz → WhatsApp (docs/TAREA-CLAUDE-HANDOFF-VOZ-WHATSAPP.md)
--
--   create_handoff(): ahora revalida consentimiento/política igual que
--   start_conversation, es idempotente (mismo to_channel+action para la misma
--   conversación no duplica), valida la acción contra el estado real
--   (compromiso existente, no pendiente de aprobación) y devuelve {ok, ...}
--   explícito en vez de lanzar excepción — el agente necesita distinguir
--   "no se puede ofrecer" (sigue la llamada) de un error real.
--
--   Eventos nuevos en conversation_events: whatsapp_handoff_offered (lo
--   registra el agente cuando pregunta), whatsapp_handoff_declined (política
--   lo rechaza, o el cliente dice que no), handoff_created (ya existía),
--   handoff_completed / handoff_failed (los registra el bot al resolver).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function create_handoff(p_conversation_id uuid, p_to_channel text, p_action text,
                                          p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv       conversations;
  c        customers;
  cm       commitments;
  pol      agent_policies := active_policy();
  existing handoffs;
  v_link   jsonb;
  v_id     uuid;
  v_sum    text;
  v_pay    jsonb := coalesce(p_payload, '{}');
  v_reason text;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  select * into c from customers where id = cv.customer_id;
  select * into cm from commitments where id = cv.commitment_id;

  if p_action not in ('SEND_PAYMENT_LINK', 'SEND_COMMITMENT_SUMMARY', 'SEND_OFFER_DETAILS', 'FOLLOW_UP_MESSAGE', 'CALLBACK') then
    return jsonb_build_object('ok', false, 'error', 'ACCION_DESCONOCIDA');
  end if;

  -- Idempotencia: ya hay un handoff vigente/resuelto igual para esta conversación → se devuelve, no se duplica
  select * into existing from handoffs
   where from_conversation_id = p_conversation_id and to_channel = p_to_channel and action = p_action
     and status in ('pending', 'processing', 'completed')
   order by created_at desc limit 1;
  if existing.id is not null then
    return jsonb_build_object('ok', true, 'idempotent', true, 'handoff_id', existing.id, 'to_channel', existing.to_channel,
                              'action', existing.action, 'status', existing.status, 'payload', existing.payload,
                              'context_summary', existing.context_summary);
  end if;

  -- Política de contacto para WhatsApp: mismas reglas que start_conversation() para el canal (0700_conversation_api.sql).
  -- OJO: no reevaluamos match_rules()/get_conversation_context() aquí — esta llamada YA fue autorizada al iniciar
  -- la conversación, y el compromiso que se acaba de registrar dispararía R-BLK-COMPROMISO-VIGENTE contra sí mismo.
  -- Solo se revisa una disputa abierta, que sí debe detener un handoff con datos financieros a mitad de conversación.
  if p_to_channel = 'whatsapp' then
    v_reason := case
      when pol.live_contact_allowlist_only and not c.contact_enabled then 'CONTACTO_NO_HABILITADO'
      when c.opted_out_at is not null then 'CLIENTE_PIDIO_NO_SER_CONTACTADO'
      when c.is_control_group then 'GRUPO_DE_CONTROL'
      when not c.consent_whatsapp then 'SIN_CONSENTIMIENTO_PARA_CANAL'
      when c.phone_e164 is null then 'SIN_TELEFONO'
      when exists (select 1 from customer_signals where customer_id = cv.customer_id and signal_type = 'OPEN_DISPUTE' and is_active)
        then 'DISPUTA_ABIERTA'
      else null
    end;
    if v_reason is not null then
      perform log_event(p_conversation_id, 'whatsapp_handoff_declined',
        jsonb_build_object('reason', v_reason, 'action', p_action, 'by', 'policy'), 'warning');
      return jsonb_build_object('ok', false, 'error', v_reason);
    end if;
  end if;

  -- Validación de la acción contra el estado real: el modelo propone, esto autoriza
  if p_action = 'SEND_PAYMENT_LINK' then
    if cm.id is null then return jsonb_build_object('ok', false, 'error', 'SIN_COMPROMISO_REGISTRADO'); end if;
    if cm.status = 'pending_approval' then return jsonb_build_object('ok', false, 'error', 'COMPROMISO_PENDIENTE_DE_APROBACION'); end if;
    if not (v_pay ? 'payment_url') then
      v_link := create_payment_link(p_conversation_id);
      v_pay  := v_pay || jsonb_build_object('payment_url', v_link->>'url', 'payment_token', v_link->>'token',
                                            'amount', v_link->'amount', 'amount_text', v_link->>'amount_text');
    end if;
  elsif p_action = 'SEND_COMMITMENT_SUMMARY' then
    if cm.id is null then return jsonb_build_object('ok', false, 'error', 'SIN_COMPROMISO_REGISTRADO'); end if;
  elsif p_action = 'SEND_OFFER_DETAILS' then
    -- solo las ofertas congeladas al iniciar la conversación (context_snapshot/allowed_offers), nunca invento del modelo
    v_pay := v_pay || jsonb_build_object('offers', coalesce(cv.allowed_offers, '[]'::jsonb));
  end if;

  v_sum := format('Conversación por %s con %s. Etapa alcanzada: %s. %s',
                  cv.channel, c.first_name, cv.current_stage,
                  coalesce('Compromiso ' || cm.receipt_code || ': ' || cm.terms_text, 'Sin compromiso registrado.'));

  insert into handoffs (customer_id, from_conversation_id, from_channel, to_channel, action, payload, context_summary)
  values (cv.customer_id, p_conversation_id, cv.channel, p_to_channel, p_action,
          v_pay || jsonb_build_object('commitment', case when cm.id is null then null else jsonb_build_object(
                     'receipt_code', cm.receipt_code, 'offer_code', cm.offer_code, 'amount', cm.amount,
                     'committed_date', cm.committed_date, 'terms_text', cm.terms_text, 'status', cm.status) end),
          v_sum)
  returning id into v_id;

  perform log_event(p_conversation_id, 'handoff_created', jsonb_build_object('handoff_id', v_id, 'to_channel', p_to_channel, 'action', p_action));
  return jsonb_build_object('ok', true, 'handoff_id', v_id, 'to_channel', p_to_channel, 'action', p_action,
                            'status', 'pending', 'payload', v_pay, 'context_summary', v_sum);
end $$;

-- claim_handoff ya era atómico (UPDATE ... WHERE status='pending' RETURNING); sin cambios.

-- Se agrega p_error: create or replace con una firma distinta crea un OVERLOAD, no reemplaza la función
-- vieja de 3 parámetros — hay que borrarla explícitamente para no dejar una llamada ambigua.
drop function if exists complete_handoff(uuid, uuid, text);

create or replace function complete_handoff(p_handoff_id uuid, p_to_conversation_id uuid default null,
                                            p_status text default 'completed', p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  h handoffs;
begin
  update handoffs set status = p_status, completed_at = now(), to_conversation_id = coalesce(p_to_conversation_id, to_conversation_id)
   where id = p_handoff_id returning * into h;
  if h.id is null then return jsonb_build_object('ok', false, 'error', 'HANDOFF_NO_EXISTE'); end if;
  if h.from_conversation_id is not null then
    perform log_event(h.from_conversation_id, case when p_status = 'completed' then 'handoff_completed' else 'handoff_failed' end,
      jsonb_build_object('handoff_id', h.id, 'to_channel', h.to_channel, 'action', h.action,
                         'to_conversation_id', h.to_conversation_id) || case when p_error is not null then jsonb_build_object('error', p_error) else '{}'::jsonb end,
      case when p_status = 'completed' then 'info' else 'error' end);
  end if;
  return jsonb_build_object('ok', true);
end $$;
