-- ═══════════════════════════════════════════════════════════════════════════
-- 0700 · API de conversación (RPC) — el contrato entre VOZ, WHATSAPP y WEB
--
--   start_conversation   → abre, congela reglas/ofertas, elige modelos
--   log_message          → transcripción
--   evaluate_turn        → CONTROLADOR: scorecard → etapa siguiente + instrucción
--   log_interruption     → barge-in real / backchannel / ruido
--   validate_offer       → ¿se puede ofrecer esto con estos parámetros?
--   register_commitment  → único write de compromiso (con recibo)
--   create_payment_link  → link de pago simulado
--   create_handoff       → siguiente paso en otro canal (llamada → WhatsApp)
--   claim_handoff        → el bot de WhatsApp toma el traspaso
--   request_escalation   → a humano
--   end_conversation     → cierre + riesgo después
--   record_model_usage   → costo/latencia por modelo
--
-- Regla de oro: el LLM PROPONE, estas funciones AUTORIZAN y ESCRIBEN.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function log_event(p_conversation_id uuid, p_type text, p_payload jsonb default '{}',
                                     p_severity text default 'info', p_latency_ms int default null)
returns void language plpgsql as $$
declare
  cv conversations;
begin
  select * into cv from conversations where id = p_conversation_id;
  insert into conversation_events (conversation_id, customer_id, event_type, severity, stage_key, payload, latency_ms)
  values (p_conversation_id, cv.customer_id, p_type, p_severity, cv.current_stage, coalesce(p_payload, '{}'), p_latency_ms);
end $$;

-- ─── Buscar cliente por teléfono (WhatsApp entrante) ──────────────────────
create or replace function find_customer_by_phone(p_phone text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('customer_id', id, 'customer_code', customer_code, 'first_name', first_name,
                            'full_name', full_name, 'contact_enabled', contact_enabled)
    from customers
   where regexp_replace(phone_e164, '[^0-9]', '', 'g') = regexp_replace(p_phone, '[^0-9]', '', 'g')
   limit 1
$$;

-- ─── Habilitar un cliente demo con TU número real ─────────────────────────
create or replace function set_demo_contact(p_customer_code text, p_phone text, p_email text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  update customers set phone_e164 = p_phone, email = coalesce(p_email, email), contact_enabled = true,
                       opted_out_at = null, opt_out_reason = null
   where customer_code = p_customer_code returning id into v_id;
  if v_id is null then raise exception 'CLIENTE_NO_EXISTE: %', p_customer_code; end if;
  return jsonb_build_object('customer_id', v_id, 'customer_code', p_customer_code, 'contact_enabled', true);
end $$;

-- ─── Iniciar conversación ──────────────────────────────────────────────────
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
begin
  select * into c from customers where id = p_customer_id;
  if c.id is null then raise exception 'CLIENTE_NO_EXISTE: %', p_customer_id; end if;

  if p_direction = 'outbound' then
    if pol.live_contact_allowlist_only and p_channel in ('voice','whatsapp','sms') and not c.contact_enabled then
      raise exception 'CONTACTO_NO_HABILITADO: % no tiene contact_enabled. Ejecuta set_demo_contact(''%'', ''+503...'').',
        c.customer_code, c.customer_code;
    end if;
    if c.opted_out_at is not null then
      raise exception 'CLIENTE_PIDIO_NO_SER_CONTACTADO: %', c.customer_code;
    end if;
    if c.is_control_group and not p_force then
      raise exception 'GRUPO_DE_CONTROL: % no se contacta (contrafactual). Usa p_force => true solo para pruebas.', c.customer_code;
    end if;
    if (p_channel = 'voice' and not c.consent_voice) or (p_channel = 'whatsapp' and not c.consent_whatsapp) then
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
                             prompt_versions)
  values (p_customer_id, nullif(v_ctx->'loan'->>'id','')::uuid, v_iv, p_parent_conversation_id, p_channel, p_direction,
          p_external_id, v_pb.id, v_pb.key, v_first, v_ctx->'rules'->'matched', v_ctx->'offers',
          v_ctx->'constraints', v_ctx->'rules'->>'tone', v_ctx, jnum(v_ctx->'risk'->'score'),
          nullif(v_arm->>'experiment_id','')::uuid, v_arm->>'arm_key', v_models, coalesce(v_prompts, '{}'))
  returning id into v_conv;

  if v_iv is not null then
    update interventions set status = 'dispatched', dispatched_at = now(), conversation_id = v_conv where id = v_iv;
  end if;

  perform log_event(v_conv, 'conversation_started', jsonb_build_object(
    'channel', p_channel, 'direction', p_direction, 'playbook', v_pb.key, 'first_stage', v_first,
    'rules', v_ctx->'rules'->'matched', 'offers', (select jsonb_agg(o->>'code') from jsonb_array_elements(v_ctx->'offers') o),
    'models', v_models, 'arm', v_arm->>'arm_key', 'warnings', v_warn));

  return jsonb_build_object(
    'conversation_id', v_conv,
    'current_stage',   v_first,
    'models',          v_models,
    'prompt_versions', coalesce(v_prompts, '{}'),
    'experiment',      v_arm,
    'warnings',        v_warn,
    'context',         v_ctx);
end $$;

-- ─── Registrar mensaje ─────────────────────────────────────────────────────
-- p_meta: latency_ms, ttfb_ms, audio_ms, input_modality, media_url, model_profile_key,
--         prompt_version_key, tokens_in, tokens_out, is_backchannel, stage_key
create or replace function log_message(p_conversation_id uuid, p_role text, p_content text, p_meta jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv     conversations;
  v_seq  int;
  v_id   uuid;
  v_stage text;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;

  select coalesce(max(seq), 0) + 1 into v_seq from messages where conversation_id = p_conversation_id;
  v_stage := coalesce(p_meta->>'stage_key', cv.current_stage);

  insert into messages (conversation_id, seq, role, content, stage_key, input_modality, media_url, latency_ms, ttfb_ms,
                        audio_ms, is_backchannel, model_profile_key, prompt_version_key, tokens_in, tokens_out, meta)
  values (p_conversation_id, v_seq, p_role, p_content, v_stage,
          coalesce(p_meta->>'input_modality', case when cv.channel = 'voice' then 'audio' else 'text' end),
          p_meta->>'media_url', jnum(p_meta->'latency_ms')::int, jnum(p_meta->'ttfb_ms')::int, jnum(p_meta->'audio_ms')::int,
          coalesce(jbool(p_meta->'is_backchannel'), false), p_meta->>'model_profile_key', p_meta->>'prompt_version_key',
          jnum(p_meta->'tokens_in')::int, jnum(p_meta->'tokens_out')::int, p_meta)
  returning id into v_id;

  update conversations set last_message_at = now() where id = p_conversation_id;

  if p_role = 'customer' and not exists (select 1 from messages where conversation_id = p_conversation_id
                                                and role = 'customer' and id <> v_id) then
    perform log_event(p_conversation_id, 'first_customer_response',
                      jsonb_build_object('seconds_since_start', extract(epoch from now() - cv.started_at)::int));
  end if;

  return jsonb_build_object('message_id', v_id, 'seq', v_seq, 'stage_key', v_stage);
end $$;

-- ─── CONTROLADOR DE CONVERSACIÓN ───────────────────────────────────────────
-- Entrada: scorecard (criterios evaluados por el supervisor LLM sobre el último intercambio)
-- Salida:  decisión determinista + mensaje [CONTROL] listo para inyectar al agente
create or replace function evaluate_turn(p_conversation_id uuid, p_scorecard jsonb, p_message_id uuid default null,
                                         p_meta jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv          conversations;
  pol         agent_policies := active_policy();
  st          playbook_stages;
  to_st       playbook_stages;
  tf          jsonb;
  g           jsonb;
  v_to        text;
  v_rule_id   text;
  v_rule_lbl  text;
  v_rule_ins  text;
  v_decision  text;
  v_pace      text;
  v_sent      text;
  v_neg       int;
  v_lowc      int;
  v_ref       int;
  v_st_turns  int;
  v_total     int;
  v_seq       int;
  v_ctrl      text;
  v_esc       uuid;
  v_offers    jsonb;
  v_eval      uuid;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  if cv.status <> 'active' then
    return jsonb_build_object('decision', 'ignored', 'reason', 'CONVERSACION_NO_ACTIVA', 'status', cv.status);
  end if;

  select * into st from playbook_stages where playbook_id = cv.playbook_id and stage_key = cv.current_stage;

  v_sent     := upper(coalesce(p_scorecard->>'sentiment', 'NEUTRAL'));
  v_neg      := case when v_sent in ('FRUSTRATED','ANGRY') then cv.negative_streak + 1 else 0 end;
  v_lowc     := case when coalesce(jnum(p_scorecard->'confidence'), 1) < 0.5 then cv.low_confidence_streak + 1 else 0 end;
  v_ref      := cv.refusal_count + case when jbool(p_scorecard->'explicit_refusal') is true then 1 else 0 end;
  v_st_turns := cv.stage_turn_count + 1;
  v_total    := cv.turn_count + 1;

  -- Hechos del turno: scorecard + contadores que el LLM NO controla
  tf := p_scorecard || jsonb_build_object(
    'stage_turns', v_st_turns, 'total_turns', v_total, 'negative_streak', v_neg,
    'low_confidence_streak', v_lowc, 'refusal_count', v_ref,
    'has_commitment', cv.commitment_id is not null,
    'terms_pending', cardinality(cv.terms_interrupted) > 0,
    'current_stage', cv.current_stage,
    'max_turns', pol.max_turns_per_conversation);

  -- 1) Transiciones globales (seguridad, respeto, escalamiento) — ganan siempre
  for g in select * from jsonb_array_elements(pol.global_transitions) loop
    if eval_condition(g->'when', tf) then
      v_to := g->>'go_to'; v_rule_id := g->>'id'; v_rule_lbl := g->>'label'; v_rule_ins := g->>'instruction';
      exit;
    end if;
  end loop;

  -- 2) Reglas de salida de la etapa actual (configuradas en la web)
  if v_to is null and st.id is not null then
    for g in select * from jsonb_array_elements(st.exit_rules) loop
      if eval_condition(g->'when', tf) then
        v_to := g->>'go_to'; v_rule_id := g->>'id'; v_rule_lbl := g->>'label'; v_rule_ins := g->>'instruction';
        exit;
      end if;
    end loop;
  end if;

  -- 3) Límite de turnos en la etapa (evita loops)
  if v_to is null and st.id is not null and v_st_turns >= st.max_turns and st.on_max_turns_go_to is not null then
    v_to := st.on_max_turns_go_to; v_rule_id := 'MAX_TURNS_' || st.stage_key;
    v_rule_lbl := format('Máximo de %s turnos en "%s"', st.max_turns, st.name);
  end if;

  if v_to is null or v_to = cv.current_stage then
    v_to := cv.current_stage; v_decision := 'stay';
    to_st := st;
  else
    select * into to_st from playbook_stages where playbook_id = cv.playbook_id and stage_key = v_to;
    if to_st.id is null then
      perform log_event(p_conversation_id, 'config_error', jsonb_build_object('missing_stage', v_to, 'rule', v_rule_id), 'error');
      v_to := cv.current_stage; v_decision := 'stay'; to_st := st;
    elsif to_st.is_terminal then
      v_decision := case when v_to = 'ESCALADO' then 'escalate' else 'end' end;
    elsif to_st.position > coalesce(st.position, 0) then
      v_decision := 'advance';
    else
      v_decision := 'jump';
    end if;
  end if;

  -- Ritmo adaptativo
  v_pace := case
    when v_sent in ('FRUSTRATED','ANGRY') or coalesce(jnum(p_scorecard->'resistance'), 0) >= 0.6 then 'slow'
    when coalesce(jnum(p_scorecard->'engagement'), 0) >= 0.7
         and p_scorecard->>'commitment_signal' in ('strong','explicit') then 'fast'
    else 'normal' end;

  -- Efectos duros
  if v_decision = 'escalate' and not cv.escalated then
    insert into escalations (conversation_id, customer_id, reason, trigger, priority, sla_due_at)
    values (p_conversation_id, cv.customer_id, coalesce(v_rule_lbl, 'Escalamiento del controlador'), v_rule_id,
            case when jbool(p_scorecard->'dispute_or_fraud') then 'urgent' else 'high' end,
            now() + interval '24 hours')
    returning id into v_esc;
    perform log_event(p_conversation_id, 'escalation_created', jsonb_build_object('escalation_id', v_esc, 'rule', v_rule_id));
  end if;

  if jbool(p_scorecard->'do_not_contact_request') is true then
    update customers set opted_out_at = now(), opt_out_reason = 'Solicitado por el cliente durante la conversación'
     where id = cv.customer_id and opted_out_at is null;
    perform log_event(p_conversation_id, 'opt_out_registered', '{}', 'warning');
  end if;

  if jbool(p_scorecard->'explicit_refusal') is true then
    perform log_event(p_conversation_id, 'refusal_detected', jsonb_build_object('refusal_count', v_ref));
  end if;

  if to_st.allows_offers then
    select coalesce(jsonb_agg(jsonb_build_object('code', o->>'code', 'name', o->>'name', 'pitch', o->>'pitch_script',
                              'requires_approval', o->'requires_approval')), '[]')
      into v_offers
      from (select o from jsonb_array_elements(cv.allowed_offers) o limit pol.max_offers_presented) s;
  end if;

  -- Mensaje de control para inyectar al agente (voz: mientras el cliente habla)
  v_ctrl := '[CONTROL] Etapa: ' || coalesce(to_st.name, v_to) || ' (' || v_to || ').'
         || coalesce(' Objetivo: ' || to_st.objective || '.', '')
         || ' Ritmo: ' || coalesce(pol.pace_instructions->>v_pace, v_pace) || ''
         || coalesce(' Instrucción: ' || v_rule_ins, '')
         || coalesce(' Guion: ' || to_st.agent_instructions, '')
         || case when cardinality(cv.terms_interrupted) > 0
                 then ' IMPORTANTE: el cliente no escuchó completas las condiciones de ' || array_to_string(cv.terms_interrupted, ', ')
                      || '. Repítelas brevemente antes de pedir confirmación.' else '' end
         || case when v_offers is not null and jsonb_array_length(v_offers) > 0
                 then ' Opciones permitidas: ' || (select string_agg(o->>'name', '; ') from jsonb_array_elements(v_offers) o) || '.'
                 else '' end;

  select coalesce(max(seq), 0) + 1 into v_seq from turn_evaluations where conversation_id = p_conversation_id;

  insert into turn_evaluations (conversation_id, message_id, seq, stage_key, scorecard, intent, sentiment, sentiment_score,
                                resistance, engagement, commitment_signal, confidence, decision, from_stage, to_stage,
                                rule_id, rule_label, pace, control_message, evaluator_model_key, latency_ms)
  values (p_conversation_id, p_message_id, v_seq, cv.current_stage, p_scorecard, p_scorecard->>'intent', v_sent,
          jnum(p_scorecard->'sentiment_score'), jnum(p_scorecard->'resistance'), jnum(p_scorecard->'engagement'),
          p_scorecard->>'commitment_signal', jnum(p_scorecard->'confidence'), v_decision, cv.current_stage, v_to,
          v_rule_id, v_rule_lbl, v_pace, v_ctrl, p_meta->>'evaluator_model_key', jnum(p_meta->'latency_ms')::int)
  returning id into v_eval;

  update conversations set
    current_stage         = v_to,
    stage_turn_count      = case when v_to <> cv.current_stage then 0 else v_st_turns end,
    turn_count            = v_total,
    negative_streak       = v_neg,
    low_confidence_streak = v_lowc,
    refusal_count         = v_ref,
    sentiment_start       = coalesce(cv.sentiment_start, v_sent),
    sentiment_end         = v_sent,
    final_intent          = coalesce(p_scorecard->>'intent', cv.final_intent),
    escalated             = cv.escalated or v_decision = 'escalate'
  where id = p_conversation_id;

  if v_to <> cv.current_stage then
    perform log_event(p_conversation_id, 'stage_changed', jsonb_build_object(
      'from', cv.current_stage, 'to', v_to, 'decision', v_decision, 'rule_id', v_rule_id, 'rule_label', v_rule_lbl));
  end if;

  return jsonb_build_object(
    'evaluation_id',     v_eval,
    'decision',          v_decision,
    'from_stage',        cv.current_stage,
    'to_stage',          v_to,
    'rule',              jsonb_build_object('id', v_rule_id, 'label', v_rule_lbl),
    'pace',              v_pace,
    'is_terminal',       coalesce(to_st.is_terminal, false),
    'suggested_outcome', to_st.suggested_outcome,
    'stage',             jsonb_build_object('key', to_st.stage_key, 'name', to_st.name, 'objective', to_st.objective,
                                            'instructions', to_st.agent_instructions, 'criteria', to_jsonb(to_st.criteria),
                                            'allows_offers', to_st.allows_offers),
    'allowed_offers',    coalesce(v_offers, '[]'),
    'terms_to_restate',  to_jsonb(cv.terms_interrupted),
    'escalation_id',     v_esc,
    'control_message',   v_ctrl);
end $$;

-- ─── Interrupciones ────────────────────────────────────────────────────────
-- p_kind: 'real' | 'backchannel' | 'false_barge_in'
-- p_heard_text: lo que alcanzó a SONAR (no lo que se generó)
create or replace function log_interruption(
  p_conversation_id uuid,
  p_kind            text,
  p_message_id      uuid default null,
  p_heard_text      text default null,
  p_played_ms       int  default null,
  p_total_ms        int  default null,
  p_customer_text   text default null,
  p_offer_code      text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv        conversations;
  pol       agent_policies := active_policy();
  ip        jsonb;
  v_codes   text[] := '{}';
  v_instr   text;
  v_crit    boolean;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  ip := pol.interruption_policy || coalesce(cv.models->'voice_realtime'->'interruption_config', '{}');

  if p_kind not in ('real','backchannel','false_barge_in') then
    raise exception 'TIPO_DE_INTERRUPCION_INVALIDO: % (usa real | backchannel | false_barge_in)', p_kind;
  end if;

  if p_message_id is not null then
    update messages set interrupted = (p_kind <> 'backchannel'), heard_text = coalesce(p_heard_text, heard_text),
                        played_ms = coalesce(p_played_ms, played_ms), audio_ms = coalesce(p_total_ms, audio_ms)
     where id = p_message_id;
  end if;

  v_crit := cv.current_stage = any(array(select jsonb_array_elements_text(ip->'critical_stages')));

  if p_kind = 'real' then
    -- Si interrumpió durante condiciones, esas ofertas quedan "no escuchadas"
    if p_offer_code is not null then
      v_codes := array[p_offer_code];
    elsif v_crit then
      v_codes := cv.terms_presented;
    end if;
    update conversations set
      interruption_count = interruption_count + 1,
      terms_interrupted  = array(select distinct unnest(terms_interrupted || v_codes))
     where id = p_conversation_id;
    v_instr := ip->>'on_interrupt_instruction';
    if cardinality(v_codes) > 0 then
      v_instr := v_instr || ' El cliente NO escuchó completas las condiciones de: ' || array_to_string(v_codes, ', ')
              || '. Antes de registrar, repítelas en una frase (llama validar_oferta otra vez).';
    end if;
  elsif p_kind = 'false_barge_in' then
    update conversations set false_barge_in_count = false_barge_in_count + 1 where id = p_conversation_id;
    v_instr := ip->>'on_false_barge_in_instruction';
  else
    update conversations set backchannel_count = backchannel_count + 1 where id = p_conversation_id;
    v_instr := ip->>'on_backchannel_instruction';
  end if;

  perform log_event(p_conversation_id, 'interruption_' || p_kind, jsonb_build_object(
    'message_id', p_message_id, 'heard_text', p_heard_text, 'played_ms', p_played_ms, 'total_ms', p_total_ms,
    'played_pct', case when coalesce(p_total_ms, 0) > 0 then round(100.0 * p_played_ms / p_total_ms) end,
    'customer_text', p_customer_text, 'terms_invalidated', to_jsonb(v_codes)),
    case when p_kind = 'real' and cardinality(v_codes) > 0 then 'warning' else 'info' end);

  return jsonb_build_object(
    'kind', p_kind,
    'must_restate_terms', cardinality(v_codes) > 0,
    'offers_to_restate', to_jsonb(v_codes),
    'control_message', '[CONTROL] ' || coalesce(v_instr, ''));
end $$;

-- Silencio prolongado del cliente
create or replace function log_silence(p_conversation_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cv  conversations;
  ip  jsonb := (select interruption_policy from agent_policies where is_active limit 1);
  v_n int;
begin
  update conversations set silence_reprompt_count = silence_reprompt_count + 1
   where id = p_conversation_id returning * into cv;
  v_n := cv.silence_reprompt_count;
  perform log_event(p_conversation_id, 'silence_reprompt', jsonb_build_object('count', v_n));
  if v_n > coalesce(jnum(ip->'max_silence_reprompts'), 2)::int then
    return jsonb_build_object('action', 'end', 'suggested_outcome', 'ABANDONED', 'suggest_handoff', 'whatsapp',
                              'control_message', '[CONTROL] ' || coalesce(ip->>'on_silence_exhausted_instruction', 'Despídete y cierra.'));
  end if;
  return jsonb_build_object('action', 'reprompt',
    'control_message', '[CONTROL] Di: "' ||
      coalesce(ip->'silence_reprompt_phrases'->>(least(v_n, 2) - 1), '¿Sigue en la línea?') || '"');
end $$;

-- ─── Validar oferta (y registrar que se dijeron las condiciones) ──────────
create or replace function validate_offer(p_conversation_id uuid, p_offer_code text, p_params jsonb default '{}',
                                          p_mark_presented boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv       conversations;
  ofr      offers;
  pol      agent_policies := active_policy();
  c        customers;
  ln       loans;
  inst     installments;
  v_today  date := sv_today();
  v_errs   text[] := '{}';
  v_norm   jsonb := '{}';
  v_vars   jsonb := '{}';
  v_cons   jsonb;
  v_due    numeric;
  v_amt    numeric;
  v_date   date;
  v_date2  date;
  v_max    int;
  v_pct    numeric;
  v_n      int;
  v_down   numeric;
  v_part   numeric;
  v_waive  numeric;
  v_terms  text;
  v_valid  boolean;
begin
  select * into cv from conversations where id = p_conversation_id;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  select * into ofr from offers where code = p_offer_code;
  if ofr.id is null or not ofr.is_active then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('OFERTA_NO_EXISTE_O_INACTIVA'), 'offer_code', p_offer_code,
      'instruction', 'No ofrezcas esto. Usa solo las opciones permitidas.');
  end if;

  if not exists (select 1 from jsonb_array_elements(cv.allowed_offers) x where x->>'code' = p_offer_code) then
    v_errs := array_append(v_errs, ('OFERTA_NO_PERMITIDA_PARA_ESTE_CLIENTE')::text);
  end if;

  select * into c from customers where id = cv.customer_id;
  select * into ln from loans where id = cv.loan_id;
  select * into inst from installments where loan_id = cv.loan_id and status in ('pending','partial','overdue')
   order by due_date limit 1;
  if inst.id is null then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('SIN_CUOTA_PENDIENTE'), 'offer_code', p_offer_code);
  end if;

  v_cons := coalesce(cv.constraints, '{}');
  v_due  := inst.amount_due - inst.amount_paid;
  p_params := coalesce(p_params, '{}');

  case ofr.offer_type
    when 'FULL_PAYMENT', 'REMINDER' then
      v_date := coalesce((p_params->>'date')::date, inst.due_date);
      if v_date < v_today then v_errs := array_append(v_errs, ('FECHA_EN_EL_PASADO')::text); end if;
      if v_date > greatest(inst.due_date, v_today) + coalesce(jnum(ofr.params->'max_days_after_due'), 0)::int then
        v_errs := array_append(v_errs, ('FECHA_POSTERIOR_AL_VENCIMIENTO')::text);
      end if;
      v_amt  := v_due + case when inst.status = 'overdue' then inst.late_fee else 0 end;
      v_norm := jsonb_build_object('amount', v_amt, 'date', v_date);
      v_vars := jsonb_build_object('monto', fmt_money(v_amt), 'fecha', fmt_date_es(v_date));

    when 'DATE_EXTENSION' then
      v_date := (p_params->>'new_date')::date;
      v_max  := least(coalesce(jnum(ofr.params->'max_days'), 30), coalesce(jnum(v_cons->'max_extension_days'), 999))::int;
      if v_date is null then
        v_errs := array_append(v_errs, ('NUEVA_FECHA_REQUERIDA')::text);
        v_date := inst.due_date + v_max;  -- sugerencia: la máxima permitida
      end if;
      if v_date <= v_today then v_errs := array_append(v_errs, ('FECHA_EN_EL_PASADO')::text); end if;
      if v_date - inst.due_date > v_max then v_errs := array_append(v_errs, (('EXCEDE_MAXIMO_DE_DIAS_' || v_max))::text); end if;
      if extract(isodow from v_date)::int = any(pol.forbidden_weekdays) then v_errs := array_append(v_errs, ('DIA_NO_PERMITIDO')::text); end if;
      v_norm := jsonb_build_object('amount', v_due, 'new_date', v_date, 'days_extended', v_date - inst.due_date,
                                   'max_date', inst.due_date + v_max);
      v_vars := jsonb_build_object('monto', fmt_money(v_due), 'nueva_fecha', fmt_date_es(v_date),
                                   'dias', (v_date - inst.due_date)::text, 'fecha_maxima', fmt_date_es(inst.due_date + v_max));

    when 'PARTIAL_PAYMENT' then
      v_pct  := greatest(coalesce(jnum(ofr.params->'min_pct'), 50), coalesce(jnum(v_cons->'min_partial_pct'), 0));
      v_amt  := coalesce(jnum(p_params->'amount'), round(v_due * v_pct / 100, 2));
      v_date := coalesce((p_params->>'date')::date, v_today);
      v_max  := coalesce(jnum(ofr.params->'remaining_max_days'), 15)::int;
      v_date2 := coalesce((p_params->>'remaining_date')::date, inst.due_date + v_max);
      if v_amt < round(v_due * v_pct / 100, 2) then v_errs := array_append(v_errs, (('MONTO_MENOR_AL_MINIMO_' || v_pct || 'PCT'))::text); end if;
      if v_amt >= v_due then v_errs := array_append(v_errs, ('MONTO_CUBRE_TOTAL_USAR_PAGO_TOTAL')::text); end if;
      if v_date < v_today or v_date > greatest(inst.due_date, v_today + 3) then v_errs := array_append(v_errs, ('FECHA_DE_PAGO_PARCIAL_INVALIDA')::text); end if;
      if v_date2 - inst.due_date > v_max then v_errs := array_append(v_errs, (('SALDO_EXCEDE_' || v_max || '_DIAS'))::text); end if;
      v_norm := jsonb_build_object('amount', v_amt, 'pay_date', v_date, 'remaining_amount', v_due - v_amt,
                                   'remaining_date', v_date2, 'min_amount', round(v_due * v_pct / 100, 2));
      v_vars := jsonb_build_object('monto', fmt_money(v_amt), 'fecha_pago', fmt_date_es(v_date),
                                   'saldo_restante', fmt_money(v_due - v_amt), 'fecha_saldo', fmt_date_es(v_date2),
                                   'monto_minimo', fmt_money(round(v_due * v_pct / 100, 2)));

    when 'INSTALLMENT_PLAN' then
      v_n := coalesce(jnum(p_params->'installments'), jnum(ofr.params->'installment_options'->0))::int;
      if not (to_jsonb(v_n) <@ (ofr.params->'installment_options')) then
        v_errs := array_append(v_errs, (('NUMERO_DE_CUOTAS_NO_PERMITIDO_OPCIONES_' || (ofr.params->>'installment_options')))::text);
      end if;
      v_down := round(v_due * coalesce(jnum(ofr.params->'down_payment_min_pct'), 20) / 100, 2);
      if jnum(p_params->'down_payment') is not null then
        if jnum(p_params->'down_payment') < v_down then v_errs := array_append(v_errs, ('PAGO_INICIAL_MENOR_AL_MINIMO')::text); end if;
        v_down := jnum(p_params->'down_payment');
      end if;
      v_part := round((v_due - v_down) / greatest(v_n, 1), 2);
      v_date := coalesce((p_params->>'first_date')::date, greatest(inst.due_date, v_today) + 15);
      v_norm := jsonb_build_object('installments', v_n, 'down_payment', v_down, 'installment_amount', v_part,
                                   'base_amount', v_due, 'first_payment_date', v_date,
                                   'frequency_days', coalesce(jnum(ofr.params->'frequency_days'), 15));
      v_vars := jsonb_build_object('pago_inicial', fmt_money(v_down), 'cuotas', v_n::text,
                                   'monto_cuota_plan', fmt_money(v_part), 'fecha_primer_pago', fmt_date_es(v_date));

    when 'FEE_WAIVER' then
      if v_today - inst.due_date < 1 then v_errs := array_append(v_errs, ('SIN_ATRASO_NO_HAY_RECARGO')::text); end if;
      if v_today - inst.due_date > coalesce(jnum(ofr.params->'max_days_past_due'), 15) then
        v_errs := array_append(v_errs, ('FUERA_DEL_PLAZO_DE_CONDONACION')::text);
      end if;
      v_waive := least(greatest(inst.late_fee, ln.late_fee_amount), coalesce(jnum(ofr.params->'max_amount'), 15));
      v_date  := v_today + coalesce(jnum(ofr.params->'pay_within_days'), 3)::int;
      v_norm  := jsonb_build_object('amount', v_due, 'waived_amount', v_waive, 'pay_by_date', v_date);
      v_vars  := jsonb_build_object('monto', fmt_money(v_due), 'monto_condonado', fmt_money(v_waive),
                                    'fecha_limite', fmt_date_es(v_date));

    when 'CALLBACK' then
      v_date := coalesce((p_params->>'callback_date')::date, v_today + 1);
      if v_date < v_today or v_date - v_today > coalesce(jnum(ofr.params->'max_days'), 5) then
        v_errs := array_append(v_errs, ('FECHA_DE_RELLAMADA_INVALIDA')::text);
      end if;
      v_norm := jsonb_build_object('callback_date', v_date, 'window', coalesce(p_params->>'window', c.preferred_contact_window, 'manana'));
      v_vars := jsonb_build_object('fecha_llamada', fmt_date_es(v_date),
                                   'franja', case coalesce(p_params->>'window', c.preferred_contact_window, 'manana')
                                               when 'tarde' then 'tarde' when 'noche' then 'noche' else 'mañana' end);

    when 'HUMAN_ADVISOR' then
      v_norm := '{}'; v_vars := '{}';
  end case;

  v_vars  := v_vars || jsonb_build_object('cliente', c.first_name, 'producto', ln.product_name,
                                          'cuota', fmt_money(v_due), 'fecha_vencimiento', fmt_date_es(inst.due_date));
  v_terms := render_template(ofr.terms_template, v_vars);
  v_valid := cardinality(v_errs) = 0;

  if v_valid and p_mark_presented and ofr.disclosure_required then
    update conversations set
      terms_presented   = array(select distinct unnest(terms_presented || array[p_offer_code])),
      terms_interrupted = array_remove(terms_interrupted, p_offer_code)
     where id = p_conversation_id;
  end if;

  perform log_event(p_conversation_id, case when v_valid then 'offer_validated' else 'offer_rejected' end,
    jsonb_build_object('offer_code', p_offer_code, 'params', p_params, 'normalized', v_norm, 'errors', to_jsonb(v_errs)),
    case when v_valid then 'info' else 'warning' end);

  return jsonb_build_object(
    'valid',                  v_valid,
    'errors',                 to_jsonb(v_errs),
    'offer_code',             ofr.code,
    'offer_name',             ofr.name,
    'offer_type',             ofr.offer_type,
    'normalized_params',      v_norm,
    'terms_text',             v_terms,
    'requires_approval',      ofr.requires_approval,
    'generates_payment_link', ofr.generates_payment_link,
    'instruction', case when v_valid
      then 'Di estas condiciones con tus palabras pero SIN cambiar montos ni fechas: "' || v_terms || '". Luego pide confirmación explícita.'
      else 'No ofrezcas esto con esos parámetros. Explica el límite con amabilidad y propone una alternativa permitida.' end);
end $$;

-- ─── Registrar compromiso (ÚNICO write; devuelve recibo) ───────────────────
create or replace function register_commitment(p_conversation_id uuid, p_offer_code text, p_params jsonb default '{}',
                                               p_customer_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv       conversations;
  ofr      offers;
  v        jsonb;
  n        jsonb;
  inst     installments;
  v_id     uuid;
  v_code   text;
  v_status text;
  v_esc    uuid;
  v_fail   jsonb;
  existing commitments;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  select * into ofr from offers where code = p_offer_code;

  -- Idempotencia: el modelo de voz puede llamar dos veces
  select * into existing from commitments
   where conversation_id = p_conversation_id and offer_code = p_offer_code and status <> 'cancelled' limit 1;
  if existing.id is not null then
    return jsonb_build_object('ok', true, 'idempotent', true, 'commitment_id', existing.id,
                              'receipt_code', existing.receipt_code, 'status', existing.status,
                              'summary', existing.terms_text);
  end if;

  v := validate_offer(p_conversation_id, p_offer_code, p_params, false);

  if not (v->>'valid')::boolean then
    v_fail := jsonb_build_object('ok', false, 'errors', v->'errors', 'instruction', v->>'instruction');
  elsif not coalesce(p_customer_confirmed, false) then
    v_fail := jsonb_build_object('ok', false, 'errors', jsonb_build_array('CONFIRMACION_EXPLICITA_REQUERIDA'),
      'instruction', 'Resume opción, monto y fecha, y pide un "sí" explícito antes de registrar.');
  elsif ofr.disclosure_required and not (p_offer_code = any(cv.terms_presented)) then
    v_fail := jsonb_build_object('ok', false, 'errors', jsonb_build_array('CONDICIONES_NO_PRESENTADAS'),
      'instruction', 'Primero llama validar_oferta y di las condiciones al cliente.');
  elsif p_offer_code = any(cv.terms_interrupted) then
    v_fail := jsonb_build_object('ok', false, 'errors', jsonb_build_array('CONDICIONES_INTERRUMPIDAS'),
      'instruction', 'El cliente interrumpió mientras escuchaba las condiciones. Repítelas brevemente (validar_oferta) y vuelve a pedir confirmación.');
  end if;

  if v_fail is not null then
    perform log_event(p_conversation_id, 'commitment_rejected',
                      jsonb_build_object('offer_code', p_offer_code, 'errors', v_fail->'errors'), 'warning');
    return v_fail;
  end if;

  n := v->'normalized_params';
  select * into inst from installments where loan_id = cv.loan_id and status in ('pending','partial','overdue')
   order by due_date limit 1;
  v_status := case when ofr.requires_approval then 'pending_approval' else 'pending' end;
  v_code   := 'CMP-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));

  insert into commitments (conversation_id, customer_id, loan_id, installment_id, offer_code, commitment_type, amount,
                           committed_date, original_due_date, params, terms_text, status, requires_approval,
                           customer_confirmed, policy_validated, receipt_code)
  values (p_conversation_id, cv.customer_id, cv.loan_id, inst.id, ofr.code, ofr.offer_type,
          coalesce(jnum(n->'down_payment'), jnum(n->'amount')),
          coalesce((n->>'new_date')::date, (n->>'pay_date')::date, (n->>'date')::date, (n->>'first_payment_date')::date,
                   (n->>'pay_by_date')::date, (n->>'callback_date')::date),
          inst.due_date, n, v->>'terms_text', v_status, ofr.requires_approval, true, true, v_code)
  returning id into v_id;

  update conversations set commitment_id = v_id where id = p_conversation_id;

  if ofr.requires_approval then
    insert into escalations (conversation_id, customer_id, reason, trigger, priority, sla_due_at)
    values (p_conversation_id, cv.customer_id, 'Aprobación requerida: ' || ofr.name, 'OFFER_REQUIRES_APPROVAL', 'medium',
            now() + interval '24 hours')
    returning id into v_esc;
  end if;

  perform log_event(p_conversation_id, 'commitment_registered', jsonb_build_object(
    'commitment_id', v_id, 'receipt_code', v_code, 'offer_code', ofr.code, 'status', v_status, 'params', n));

  return jsonb_build_object(
    'ok', true,
    'commitment_id', v_id,
    'receipt_code', v_code,
    'status', v_status,
    'requires_approval', ofr.requires_approval,
    'approval_escalation_id', v_esc,
    'summary', v->>'terms_text',
    'next_steps', case when ofr.generates_payment_link or ofr.offer_type in ('FULL_PAYMENT','PARTIAL_PAYMENT','INSTALLMENT_PLAN','FEE_WAIVER')
                       then jsonb_build_array('OFRECER_LINK_DE_PAGO_POR_WHATSAPP') else '[]'::jsonb end,
    'instruction', case when ofr.requires_approval
      then 'Confirma que la SOLICITUD quedó registrada y que está sujeta a aprobación. No digas que está aprobada.'
      else 'Confirma que quedó registrado. Puedes ofrecer enviar el resumen y el link de pago por WhatsApp.' end);
end $$;

-- ─── Link de pago (simulado) ───────────────────────────────────────────────
create or replace function create_payment_link(p_conversation_id uuid, p_amount numeric default null,
                                               p_commitment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv      conversations;
  pol     agent_policies := active_policy();
  cm      commitments;
  inst    installments;
  v_amt   numeric;
  v_tok   text := replace(gen_random_uuid()::text, '-', '');
  v_id    uuid;
  v_url   text;
begin
  select * into cv from conversations where id = p_conversation_id;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  select * into cm from commitments where id = coalesce(p_commitment_id, cv.commitment_id);
  select * into inst from installments where loan_id = cv.loan_id and status in ('pending','partial','overdue')
   order by due_date limit 1;

  v_amt := coalesce(p_amount, cm.amount, inst.amount_due - inst.amount_paid);
  if v_amt is null or v_amt <= 0 then raise exception 'MONTO_INVALIDO_PARA_LINK'; end if;
  v_url := pol.payment_link_base_url || v_tok;

  insert into payment_links (token, customer_id, loan_id, conversation_id, commitment_id, amount, concept, url, expires_at)
  values (v_tok, cv.customer_id, cv.loan_id, p_conversation_id, cm.id, v_amt,
          coalesce('Compromiso ' || cm.receipt_code, 'Pago de cuota'), v_url,
          now() + make_interval(hours => pol.payment_link_ttl_hours))
  returning id into v_id;

  perform log_event(p_conversation_id, 'payment_link_created', jsonb_build_object('payment_link_id', v_id, 'amount', v_amt, 'url', v_url));
  return jsonb_build_object('payment_link_id', v_id, 'token', v_tok, 'url', v_url, 'amount', v_amt,
                            'amount_text', fmt_money(v_amt), 'expires_at', now() + make_interval(hours => pol.payment_link_ttl_hours));
end $$;

-- Página pública de pago (anon)
create or replace function get_payment_link(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl payment_links;
  c  customers;
begin
  select * into pl from payment_links where token = p_token;
  if pl.id is null then return jsonb_build_object('found', false); end if;
  if pl.status = 'active' and pl.expires_at < now() then
    update payment_links set status = 'expired' where id = pl.id; pl.status := 'expired';
  end if;
  if pl.opened_at is null then update payment_links set opened_at = now() where id = pl.id; end if;
  select * into c from customers where id = pl.customer_id;
  return jsonb_build_object('found', true, 'first_name', c.first_name, 'amount', pl.amount,
                            'amount_text', fmt_money(pl.amount), 'concept', pl.concept, 'status', pl.status,
                            'expires_at', pl.expires_at);
end $$;

-- Simula el pago (botón "Pagar" de la página demo) → cierra el ciclo en el dashboard
create or replace function simulate_payment(p_token text, p_method text default 'tarjeta') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl        payment_links;
  v_left    numeric;
  inst      installments;
  v_apply   numeric;
  v_pay     uuid;
  v_today   date := sv_today();
begin
  select * into pl from payment_links where token = p_token for update;
  if pl.id is null then raise exception 'LINK_NO_EXISTE'; end if;
  if pl.status <> 'active' or pl.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'LINK_NO_ACTIVO', 'status', pl.status);
  end if;

  v_left := pl.amount;
  for inst in select * from installments where loan_id = pl.loan_id and status in ('overdue','partial','pending')
               order by due_date loop
    exit when v_left <= 0;
    v_apply := least(v_left, inst.amount_due - inst.amount_paid);
    insert into payments (customer_id, loan_id, installment_id, amount, paid_at, channel, reference, payment_link_id, is_synthetic)
    values (pl.customer_id, pl.loan_id, inst.id, v_apply, now(), 'link_pago', p_method || ':' || left(p_token, 8), pl.id, false)
    returning id into v_pay;
    update installments set
      amount_paid = amount_paid + v_apply,
      paid_at     = case when amount_paid + v_apply >= amount_due then v_today else paid_at end,
      days_late   = case when amount_paid + v_apply >= amount_due then greatest(0, v_today - due_date) else days_late end,
      status      = case when amount_paid + v_apply >= amount_due
                         then case when v_today > due_date then 'paid_late' else 'paid' end
                         else 'partial' end
     where id = inst.id;
    v_left := v_left - v_apply;
  end loop;

  update loans set balance = greatest(0, balance - pl.amount) where id = pl.loan_id;
  update payment_links set status = 'paid', paid_at = now() where id = pl.id;
  update commitments set status = 'kept', resolved_at = now()
   where id = pl.commitment_id and status in ('pending','approved') and pl.amount >= coalesce(amount, 0);

  if pl.conversation_id is not null then
    perform log_event(pl.conversation_id, 'payment_received', jsonb_build_object('amount', pl.amount, 'method', p_method,
                                                                                  'payment_link_id', pl.id));
  end if;
  perform compute_risk(pl.customer_id, true, 'payment');

  return jsonb_build_object('ok', true, 'amount', pl.amount, 'amount_text', fmt_money(pl.amount),
                            'receipt', 'PAY-' || upper(left(p_token, 8)));
end $$;

-- ─── Traspaso a otro canal ─────────────────────────────────────────────────
create or replace function create_handoff(p_conversation_id uuid, p_to_channel text, p_action text,
                                          p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv     conversations;
  c      customers;
  cm     commitments;
  v_link jsonb;
  v_id   uuid;
  v_sum  text;
  v_pay  jsonb := coalesce(p_payload, '{}');
begin
  select * into cv from conversations where id = p_conversation_id;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  select * into c from customers where id = cv.customer_id;
  select * into cm from commitments where id = cv.commitment_id;

  if p_action = 'SEND_PAYMENT_LINK' and not (v_pay ? 'payment_url') then
    v_link := create_payment_link(p_conversation_id);
    v_pay  := v_pay || jsonb_build_object('payment_url', v_link->>'url', 'payment_token', v_link->>'token',
                                          'amount', v_link->'amount', 'amount_text', v_link->>'amount_text');
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

  perform log_event(p_conversation_id, 'handoff_created', jsonb_build_object('handoff_id', v_id, 'to_channel', p_to_channel,
                                                                              'action', p_action));
  return jsonb_build_object('handoff_id', v_id, 'to_channel', p_to_channel, 'action', p_action, 'payload', v_pay,
                            'context_summary', v_sum);
end $$;

create or replace function claim_handoff(p_handoff_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  h handoffs;
begin
  update handoffs set status = 'processing', claimed_at = now()
   where id = p_handoff_id and status = 'pending' returning * into h;
  if h.id is null then
    return jsonb_build_object('ok', false, 'error', 'HANDOFF_NO_DISPONIBLE');
  end if;
  return jsonb_build_object('ok', true, 'handoff', to_jsonb(h));
end $$;

create or replace function complete_handoff(p_handoff_id uuid, p_to_conversation_id uuid default null,
                                            p_status text default 'completed')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update handoffs set status = p_status, completed_at = now(), to_conversation_id = p_to_conversation_id
   where id = p_handoff_id;
  return jsonb_build_object('ok', true);
end $$;

-- ─── Escalar a humano ──────────────────────────────────────────────────────
create or replace function request_escalation(p_conversation_id uuid, p_reason text, p_priority text default 'high',
                                              p_trigger text default 'AGENT_TOOL')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv   conversations;
  v_id uuid;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  insert into escalations (conversation_id, customer_id, reason, trigger, priority, sla_due_at)
  values (p_conversation_id, cv.customer_id, p_reason, p_trigger, p_priority, now() + interval '24 hours')
  returning id into v_id;
  update conversations set escalated = true,
         current_stage = case when exists (select 1 from playbook_stages where playbook_id = cv.playbook_id and stage_key = 'ESCALADO')
                              then 'ESCALADO' else current_stage end
   where id = p_conversation_id;
  perform log_event(p_conversation_id, 'escalation_created', jsonb_build_object('escalation_id', v_id, 'reason', p_reason,
                                                                                 'priority', p_priority));
  return jsonb_build_object('escalation_id', v_id,
    'instruction', 'Informa al cliente que un asesor le contactará en un máximo de 24 horas hábiles y despídete con amabilidad.');
end $$;

-- ─── Costo por modelo ──────────────────────────────────────────────────────
-- p_usage: audio_in_seconds, audio_out_seconds, audio_in_tokens, audio_out_tokens,
--          text_in_tokens, text_out_tokens, cached_tokens, latency_ms, ttfb_ms, error, role
create or replace function record_model_usage(p_conversation_id uuid, p_model_key text, p_usage jsonb,
                                              p_eval_run_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m      ai_model_profiles;
  p      jsonb;
  u      jsonb := coalesce(p_usage, '{}');
  v_cost numeric := 0;
begin
  select * into m from ai_model_profiles where key = p_model_key;
  p := coalesce(m.pricing, '{}');

  -- audio: por token si viene, si no por minuto
  if coalesce(jnum(u->'audio_in_tokens'), 0) > 0 then
    v_cost := v_cost + jnum(u->'audio_in_tokens') / 1e6 * coalesce(jnum(p->'audio_in_per_1m'), 0);
  else
    v_cost := v_cost + coalesce(jnum(u->'audio_in_seconds'), 0) / 60 * coalesce(jnum(p->'audio_in_per_min'), 0);
  end if;
  if coalesce(jnum(u->'audio_out_tokens'), 0) > 0 then
    v_cost := v_cost + jnum(u->'audio_out_tokens') / 1e6 * coalesce(jnum(p->'audio_out_per_1m'), 0);
  else
    v_cost := v_cost + coalesce(jnum(u->'audio_out_seconds'), 0) / 60 * coalesce(jnum(p->'audio_out_per_min'), 0);
  end if;
  v_cost := v_cost
          + coalesce(jnum(u->'text_in_tokens'), 0)  / 1e6 * coalesce(jnum(p->'text_in_per_1m'), 0)
          + coalesce(jnum(u->'text_out_tokens'), 0) / 1e6 * coalesce(jnum(p->'text_out_per_1m'), 0)
          + coalesce(jnum(u->'characters'), 0)      / 1e6 * coalesce(jnum(p->'per_1m_characters'), 0);

  insert into model_usage (conversation_id, eval_run_id, model_profile_key, role, provider, model_id,
                           audio_in_seconds, audio_out_seconds, audio_in_tokens, audio_out_tokens,
                           text_in_tokens, text_out_tokens, cached_tokens, latency_ms, ttfb_ms, cost_usd, error)
  values (p_conversation_id, p_eval_run_id, p_model_key, coalesce(u->>'role', m.role), m.provider, m.model_id,
          coalesce(jnum(u->'audio_in_seconds'), 0), coalesce(jnum(u->'audio_out_seconds'), 0),
          coalesce(jnum(u->'audio_in_tokens'), 0)::int, coalesce(jnum(u->'audio_out_tokens'), 0)::int,
          coalesce(jnum(u->'text_in_tokens'), 0)::int, coalesce(jnum(u->'text_out_tokens'), 0)::int,
          coalesce(jnum(u->'cached_tokens'), 0)::int, jnum(u->'latency_ms')::int, jnum(u->'ttfb_ms')::int,
          round(v_cost, 6), u->>'error');

  if p_conversation_id is not null then
    update conversations set cost_usd = cost_usd + round(v_cost, 5) where id = p_conversation_id;
  end if;
  return jsonb_build_object('cost_usd', round(v_cost, 6), 'pricing_verified_at', m.pricing_verified_at);
end $$;

-- ─── Cerrar conversación ───────────────────────────────────────────────────
create or replace function end_conversation(p_conversation_id uuid, p_outcome text, p_summary text default null,
                                            p_meta jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cv       conversations;
  od       outcome_definitions;
  v_risk   jsonb;
  v_avg    int;
  v_p95    int;
  cm       commitments;
begin
  select * into cv from conversations where id = p_conversation_id for update;
  if cv.id is null then raise exception 'CONVERSACION_NO_EXISTE: %', p_conversation_id; end if;
  if cv.status <> 'active' then
    return jsonb_build_object('ok', true, 'idempotent', true, 'outcome', cv.outcome);
  end if;
  select * into od from outcome_definitions where code = p_outcome;
  if od.code is null then
    raise exception 'RESULTADO_INVALIDO: %. Consulta outcome_definitions.', p_outcome;
  end if;

  select avg(latency_ms)::int, (percentile_cont(0.95) within group (order by latency_ms))::int
    into v_avg, v_p95
    from messages where conversation_id = p_conversation_id and role = 'agent' and latency_ms is not null;

  v_risk := compute_risk(cv.customer_id, true, 'post_conversation');
  select * into cm from commitments where id = cv.commitment_id;

  update conversations set
    status         = case p_outcome when 'NO_ANSWER' then 'no_answer' when 'FAILED' then 'failed' else 'completed' end,
    outcome        = p_outcome,
    outcome_reason = p_meta->>'reason',
    summary        = coalesce(p_summary, summary),
    recording_url  = coalesce(p_meta->>'recording_url', recording_url),
    ended_at       = now(),
    duration_ms    = (extract(epoch from now() - started_at) * 1000)::int,
    avg_latency_ms = v_avg,
    p95_latency_ms = v_p95,
    risk_after     = (v_risk->>'score')::int
   where id = p_conversation_id;

  update interventions set status = 'completed', completed_at = now() where id = cv.intervention_id;

  perform log_event(p_conversation_id, 'conversation_ended', jsonb_build_object(
    'outcome', p_outcome, 'risk_before', cv.risk_before, 'risk_after', v_risk->'score',
    'commitment_receipt', cm.receipt_code, 'avg_latency_ms', v_avg, 'p95_latency_ms', v_p95));

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'outcome_label', od.label,
                            'risk_before', cv.risk_before, 'risk_after', v_risk->'score',
                            'commitment_receipt', cm.receipt_code, 'avg_latency_ms', v_avg, 'p95_latency_ms', v_p95);
end $$;
