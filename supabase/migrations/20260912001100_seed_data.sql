-- ═══════════════════════════════════════════════════════════════════════════
-- 1100 · Seed de DATOS (clientes ficticios, créditos, historial, conversaciones)
--
--   select reset_demo();          ← deja TODO en el estado inicial de la demo
--   select reset_demo(false);     ← conserva la configuración editada en la web
--
-- 100% determinista: mismas llaves → mismos datos. Fechas RELATIVAS a hoy (SV):
-- la demo siempre tiene cuotas "por vencer en 3 días".
-- ⚠️ Teléfonos +50300xxxxxx no son enrutables; emails @correo-demo.test.
-- ⚠️ Las diferencias intervenido vs control SON GENERADAS: ilustrativas, no evidencia.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Inserta cliente + crédito + cuotas + pagos + señales desde una especificación ──
create or replace function seed_insert_customer(p jsonb) returns uuid
language plpgsql as $seed$
declare
  v_today    date := sv_today();
  v_cid      uuid := coalesce((p->>'id')::uuid, gen_random_uuid());
  v_lid      uuid := gen_random_uuid();
  l          jsonb := p->'loan';
  v_code     text := p->>'code';
  v_P        numeric := jnum(l->'principal');
  v_rate     numeric := jnum(l->'rate');
  v_n        int := jnum(l->'term')::int;
  v_r        numeric;
  v_A        numeric;
  v_paid     int := jnum(l->'months_paid')::int;
  v_off      int := jnum(l->'next_due_offset')::int;
  v_next     date;
  v_pat      jsonb := coalesce(l->'late_pattern', '[]');
  v_plen     int;
  v_parts    jsonb := coalesce(l->'partial_idx', '[]');
  v_fee_amt  numeric := coalesce(jnum(l->'late_fee'), 10);
  j          int;
  idx        int;
  v_due      date;
  v_first    date;
  v_bal      numeric;
  v_int      numeric;
  v_prin     numeric;
  v_late     int;
  v_iid      uuid;
  v_at       timestamptz;
  v_chan     text;
  v_loan_bal numeric;
  s          jsonb;
begin
  v_r    := v_rate / 12;
  v_A    := round(v_P * v_r / (1 - power(1 + v_r, -v_n)), 2);
  v_next := v_today + v_off;
  v_plen := jsonb_array_length(v_pat);
  v_first := (v_next - make_interval(months => v_paid))::date;

  insert into customers (id, customer_code, first_name, last_name, gender, birth_date, document_id, phone_e164, email,
                         department, city, address_zone, segment, income_type, monthly_income, occupation, agro_profile,
                         preferred_channel, preferred_contact_window, consent_voice, consent_whatsapp,
                         is_control_group, is_demo_persona, risk_profile_seed, demo_notes, customer_since,
                         opted_out_at, opt_out_reason)
  values (v_cid, v_code, p->>'first', p->>'last', p->>'gender',
          v_today - (jnum(p->'age')::int * 365 + dint(v_code || ':bd', 0, 300)),
          'DOC-' || v_code, p->>'phone', p->>'email', p->>'dept', p->>'city', p->>'zone', p->>'segment',
          p->>'income_type', jnum(p->'income'), p->>'occupation', p->'agro', p->>'channel', p->>'window',
          coalesce(jbool(p->'consent_voice'), true), coalesce(jbool(p->'consent_whatsapp'), true),
          coalesce(jbool(p->'control'), false), coalesce(jbool(p->'persona'), false), p->>'profile', p->>'notes',
          v_first - dint(v_code || ':since', 60, 1800),
          case when jnum(p->'opted_out_days_ago') is not null then now() - make_interval(days => jnum(p->'opted_out_days_ago')::int) end,
          p->>'opt_out_reason');

  insert into loans (id, customer_id, loan_number, product_type, product_name, purpose, principal, annual_rate, term_months,
                     installment_amount, balance, disbursed_at, payment_day, late_fee_amount)
  values (v_lid, v_cid, 'CR-' || v_code, l->>'product', l->>'name', l->>'purpose', v_P, v_rate, v_n, v_A, v_P,
          (v_first - interval '1 month')::date, extract(day from v_next)::int, v_fee_amt);

  v_bal := v_P;
  for j in 1 .. least(v_paid + 2, v_n) loop
    v_due  := (v_next - make_interval(months => v_paid + 1 - j))::date;
    v_int  := round(v_bal * v_r, 2);
    v_prin := v_A - v_int;

    if j <= v_paid then
      idx    := j - (v_paid - v_plen) - 1;
      v_late := case when idx >= 0 then coalesce(jnum(v_pat -> idx)::int, 0) else 0 end;
      v_late := greatest(0, least(v_late, v_today - 1 - v_due));

      insert into installments (loan_id, number, due_date, amount_due, principal_part, interest_part, amount_paid,
                                paid_at, days_late, late_fee, status)
      values (v_lid, j, v_due, v_A, v_prin, v_int, v_A, v_due + v_late, v_late,
              case when v_late > 3 then v_fee_amt else 0 end,
              case when v_late > 0 then 'paid_late' else 'paid' end)
      returning id into v_iid;

      v_chan := dpick(v_code || ':ch:' || j, array['app','app','banca_en_linea','agencia','corresponsal','debito_automatico']);
      v_at   := ((v_due + v_late)::timestamp + make_interval(hours => dint(v_code || ':h:' || j, 8, 19),
                                                            mins => dint(v_code || ':mi:' || j, 0, 59)))
                at time zone 'America/El_Salvador';

      if idx >= 0 and v_parts @> to_jsonb(idx) and v_late > 2 then
        insert into payments (customer_id, loan_id, installment_id, amount, paid_at, channel, reference)
        values (v_cid, v_lid, v_iid, round(v_A * 0.6, 2), v_at - make_interval(days => greatest(1, v_late / 2)), v_chan, 'SEED-' || v_code || '-' || j || 'a'),
               (v_cid, v_lid, v_iid, v_A - round(v_A * 0.6, 2), v_at, v_chan, 'SEED-' || v_code || '-' || j || 'b');
      else
        insert into payments (customer_id, loan_id, installment_id, amount, paid_at, channel, reference)
        values (v_cid, v_lid, v_iid, v_A, v_at, v_chan, 'SEED-' || v_code || '-' || j);
      end if;
      v_bal := greatest(0, v_bal - v_prin);

    elsif j = v_paid + 1 then
      v_loan_bal := v_bal;
      insert into installments (loan_id, number, due_date, amount_due, principal_part, interest_part, amount_paid,
                                days_late, late_fee, status)
      values (v_lid, j, v_due, v_A, v_prin, v_int, coalesce(jnum(l->'overdue_paid'), 0),
              greatest(0, v_today - v_due),
              case when v_today - v_due > 3 then v_fee_amt else 0 end,
              case when v_due < v_today then 'overdue' else 'pending' end);
      v_bal := greatest(0, v_bal - v_prin);
    else
      insert into installments (loan_id, number, due_date, amount_due, principal_part, interest_part, status)
      values (v_lid, j, v_due, v_A, v_prin, v_int, 'pending');
    end if;
  end loop;

  update loans set balance = coalesce(v_loan_bal, v_bal) where id = v_lid;

  for s in select * from jsonb_array_elements(coalesce(p->'signals', '[]')) loop
    insert into customer_signals (customer_id, signal_type, severity, detail, source, detected_at, expires_at)
    values (v_cid, s->>0, s->>1, s->>2, coalesce(s->>4, 'core_bancario'),
            now() - make_interval(days => coalesce(jnum(s->3), 5)::int),
            now() + interval '60 days');
  end loop;

  return v_cid;
end $seed$;

-- ─── Arquetipos de conversación (transcripciones de ejemplo) ───────────────
create or replace function seed_archetypes() returns jsonb
language sql immutable as $seed$
select $j${
"A_COOPERATIVO": {"outcome":"PAYMENT_COMMITMENT","offer":"PAGO_TOTAL","link":true,"handoff":"SEND_PAYMENT_LINK","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, soy yo.","sc":{"identity_confirmed":"yes","intent":"CONFIRMS","sentiment":"NEUTRAL","sentiment_score":0.1,"engagement":0.6,"resistance":0.1,"confidence":0.95}},
 {"r":"agent","s":"CONTEXTO","t":"Gracias. Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Tiene previsto pagarla en esa fecha?"},
 {"r":"customer","t":"Sí, claro. El viernes le pago sin falta.","sc":{"intent":"WILL_PAY","payment_capacity":"full","commitment_signal":"strong","extracted_date_text":"el viernes","sentiment":"POSITIVE","sentiment_score":0.5,"engagement":0.8,"resistance":0.05,"confidence":0.9}},
 {"r":"agent","s":"COMPROMISO","t":"Excelente. ¿Dejamos registrado el pago de {monto} a más tardar el {fecha}?"},
 {"r":"customer","t":"Sí, déjelo así.","sc":{"commitment_signal":"explicit","offer_interest":"accepted","offer_code":"PAGO_TOTAL","confirmation_given":"yes","sentiment":"POSITIVE","sentiment_score":0.5,"engagement":0.8,"confidence":0.92}},
 {"r":"agent","s":"CONFIRMACION","t":"Listo, quedó registrado con el código {recibo}. ¿Le envío por WhatsApp un link seguro para pagar en línea?","commit":true},
 {"r":"customer","t":"Sí, mándemelo, gracias.","sc":{"accepts_whatsapp_followup":"yes","sentiment":"POSITIVE","sentiment_score":0.6,"confidence":0.95}},
 {"r":"agent","s":"SIGUIENTE_PASO","t":"Con gusto, se lo envío ahora mismo. ¡Que tenga un excelente día, {nombre}!"}]},

"B_EVASIVO": {"outcome":"FOLLOW_UP_REQUIRED","offer":null,"handoff":"SEND_OFFER_DETAILS","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, ¿qué pasó?","sc":{"identity_confirmed":"yes","intent":"ASKS_QUESTION","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.4,"resistance":0.2,"confidence":0.85}},
 {"r":"agent","s":"CONTEXTO","t":"Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Le funciona pagar en esa fecha?"},
 {"r":"customer","t":"Ahorita no sé, después veo eso.","sc":{"intent":"EVASIVE","payment_capacity":"unknown","commitment_signal":"none","sentiment":"NEUTRAL","sentiment_score":-0.1,"engagement":0.3,"resistance":0.45,"confidence":0.8}},
 {"r":"agent","s":"DESCUBRIMIENTO","t":"Entiendo. Solo para ayudarle a organizarse: ¿hay algo que le complique pagar en esa fecha?"},
 {"r":"customer","t":"No, es que ando ocupado. Luego reviso.","sc":{"intent":"EVASIVE","difficulty_reason":"none","resistance":0.5,"engagement":0.3,"sentiment":"NEUTRAL","sentiment_score":-0.1,"confidence":0.75}},
 {"r":"agent","s":"PROPUESTA","t":"Sin problema. ¿Prefiere que le envíe las opciones por WhatsApp para revisarlas con calma?"},
 {"r":"customer","t":"Sí, mándeme eso por WhatsApp.","sc":{"accepts_whatsapp_followup":"yes","offer_interest":"interested","commitment_signal":"weak","sentiment":"NEUTRAL","sentiment_score":0.1,"confidence":0.85}},
 {"r":"agent","s":"CIERRE","t":"Perfecto, se lo envío ahora. Gracias por su tiempo, {nombre}."}]},

"C_DIFICULTAD": {"outcome":"PAYMENT_PLAN_AGREED","offer":"PLAN_3_CUOTAS","link":true,"handoff":"SEND_PAYMENT_LINK","signal":"CUSTOMER_REPORTED_DIFFICULTY","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, soy yo.","sc":{"identity_confirmed":"yes","intent":"CONFIRMS","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.6,"confidence":0.95}},
 {"r":"agent","s":"CONTEXTO","t":"Gracias. Le contacto con anticipación porque su cuota de {monto} vence el {fecha}. ¿Cómo se encuentra para ese pago?"},
 {"r":"customer","t":"Mire, este mes ando complicado. Me atrasaron el pago en el trabajo.","sc":{"intent":"FINANCIAL_DIFFICULTY","payment_capacity":"partial","difficulty_reason":"income_delay","sentiment":"CONCERNED","sentiment_score":-0.35,"engagement":0.7,"resistance":0.2,"confidence":0.9}},
 {"r":"agent","s":"DESCUBRIMIENTO","t":"Lamento escuchar eso, y gracias por contármelo. ¿Podría cubrir una parte ahora y el resto en unas semanas?"},
 {"r":"customer","t":"Una parte sí, pero toda de un solo no puedo.","sc":{"payment_capacity":"partial","offer_interest":"interested","sentiment":"CONCERNED","sentiment_score":-0.2,"engagement":0.75,"confidence":0.88}},
 {"r":"agent","s":"PROPUESTA","t":"Tengo una opción: un pago inicial de {pago_inicial} y el resto en 3 pagos de {monto_cuota_plan} cada 15 días, sin intereses adicionales. ¿Le serviría?","offer_presented":true},
 {"r":"customer","t":"Sí, eso sí lo puedo hacer.","sc":{"offer_interest":"accepted","offer_code":"PLAN_3_CUOTAS","commitment_signal":"strong","sentiment":"NEUTRAL","sentiment_score":0.2,"engagement":0.8,"confidence":0.9}},
 {"r":"agent","s":"COMPROMISO","t":"Muy bien. ¿Qué día de esta semana puede hacer el pago inicial?"},
 {"r":"customer","t":"El viernes, que es cuando me depositan.","sc":{"commitment_signal":"explicit","extracted_date_text":"el viernes","sentiment":"NEUTRAL","sentiment_score":0.2,"confidence":0.9}},
 {"r":"agent","s":"CONFIRMACION","t":"Confirmo: pago inicial de {pago_inicial} el {nueva_fecha} y 3 pagos de {monto_cuota_plan} cada 15 días. ¿Lo registramos así?"},
 {"r":"customer","t":"Sí, está bien.","sc":{"confirmation_given":"yes","commitment_signal":"explicit","sentiment":"NEUTRAL","sentiment_score":0.3,"confidence":0.95}},
 {"r":"agent","s":"SIGUIENTE_PASO","t":"Quedó registrado con el código {recibo}. Le envío por WhatsApp el resumen y el link para el pago inicial.","commit":true},
 {"r":"customer","t":"Muchas gracias, la verdad me ayuda bastante.","sc":{"accepts_whatsapp_followup":"yes","sentiment":"POSITIVE","sentiment_score":0.6,"confidence":0.95}},
 {"r":"agent","s":"CIERRE","t":"Para eso estamos, {nombre}. Que le vaya muy bien."}]},

"D_MOLESTO": {"outcome":"HUMAN_ESCALATION","offer":null,"escalate":"Frustración sostenida (2 turnos)","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, ¿otra vez ustedes?","sc":{"identity_confirmed":"yes","intent":"ANGRY","sentiment":"FRUSTRATED","sentiment_score":-0.5,"engagement":0.3,"resistance":0.7,"confidence":0.85}},
 {"r":"agent","s":"CONTEXTO","t":"Disculpe la molestia, {nombre}. Seré breve: su cuota de {monto} vence el {fecha} y queremos ayudarle antes de que genere recargos.","interrupt_voice":"Disculpe la molestia, {nombre}. Seré breve: su cuota"},
 {"r":"customer","t":"Ya me tienen cansado con estas llamadas, siempre es lo mismo.","sc":{"intent":"ANGRY","sentiment":"ANGRY","sentiment_score":-0.8,"engagement":0.2,"resistance":0.9,"confidence":0.9}},
 {"r":"agent","s":"OBJECIONES","t":"Tiene razón en sentirse así y lo lamento. No quiero presionarle. ¿Prefiere que un asesor le atienda personalmente?"},
 {"r":"customer","t":"Sí, mejor que me llame una persona.","sc":{"requests_human":"yes","sentiment":"FRUSTRATED","sentiment_score":-0.5,"resistance":0.6,"confidence":0.92}},
 {"r":"agent","s":"ESCALADO","t":"Entendido. Un asesor le contactará en un máximo de 24 horas hábiles. Gracias por su paciencia."}]},

"E_PIDE_HUMANO": {"outcome":"HUMAN_ESCALATION","offer":null,"escalate":"Cliente pide un humano","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, soy yo. ¿De qué se trata?","sc":{"identity_confirmed":"yes","intent":"ASKS_QUESTION","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.5,"confidence":0.9}},
 {"r":"agent","s":"CONTEXTO","t":"Le contacto con anticipación porque su cuota de {monto} vence el {fecha}. ¿Tiene previsto pagarla en esa fecha?"},
 {"r":"customer","t":"Mire, prefiero hablar con una persona, no con una grabación.","sc":{"requests_human":"yes","intent":"REQUESTS_HUMAN","sentiment":"NEUTRAL","sentiment_score":-0.2,"resistance":0.4,"confidence":0.95}},
 {"r":"agent","s":"ESCALADO","t":"Claro que sí. Un asesor le contactará en un máximo de 24 horas hábiles. Gracias, {nombre}."}]},

"F_NEGATIVA": {"outcome":"EXPLICIT_REFUSAL","offer":null,"lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí.","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.3,"confidence":0.8}},
 {"r":"agent","s":"CONTEXTO","t":"Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Tiene previsto pagarla en esa fecha?"},
 {"r":"customer","t":"No, no voy a pagar eso ahorita.","sc":{"explicit_refusal":"yes","intent":"REFUSES","sentiment":"FRUSTRATED","sentiment_score":-0.4,"resistance":0.8,"engagement":0.2,"confidence":0.9}},
 {"r":"agent","s":"OBJECIONES","t":"Entiendo y respeto su decisión. Si le sirve, puedo enviarle por WhatsApp las opciones disponibles para cuando guste revisarlas. ¿Le parece?"},
 {"r":"customer","t":"No, gracias.","sc":{"explicit_refusal":"yes","accepts_whatsapp_followup":"no","sentiment":"NEUTRAL","sentiment_score":-0.2,"resistance":0.8,"confidence":0.9}},
 {"r":"agent","s":"NEGATIVA_RESPETADA","t":"De acuerdo, {nombre}. Gracias por atenderme. Si necesita algo, estamos para ayudarle."}]},

"G_AGRO": {"outcome":"PENDING_APPROVAL","offer":"EXTENSION_POST_COSECHA","handoff":"SEND_COMMITMENT_SUMMARY","approval":true,"lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Buenas, sí, soy yo.","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":0.1,"engagement":0.6,"confidence":0.9}},
 {"r":"agent","s":"CONTEXTO","t":"Le contacto con anticipación: la cuota de su crédito agrícola, {monto}, vence el {fecha}. ¿Cómo va para ese pago?"},
 {"r":"customer","t":"Uy, ahorita está difícil. La cosecha de {cultivo} empieza hasta noviembre y no hay entrada.","sc":{"intent":"FINANCIAL_DIFFICULTY","payment_capacity":"none","difficulty_reason":"harvest","sentiment":"CONCERNED","sentiment_score":-0.3,"engagement":0.7,"confidence":0.9}},
 {"r":"agent","s":"DESCUBRIMIENTO","t":"Lo entiendo, el ingreso del campo llega con la cosecha. ¿Para qué fecha espera tener la venta?"},
 {"r":"customer","t":"Para finales de noviembre ya estaría vendiendo.","sc":{"payment_capacity":"none","extracted_date_text":"finales de noviembre","engagement":0.8,"sentiment":"NEUTRAL","sentiment_score":0,"confidence":0.85}},
 {"r":"agent","s":"PROPUESTA","t":"Podemos solicitar mover su cuota de {monto} al {nueva_fecha}, alineada con su cosecha. Está sujeta a aprobación de un asesor. ¿Desea que la solicitemos?","offer_presented":true},
 {"r":"customer","t":"Sí, por favor, eso me ayudaría mucho.","sc":{"offer_interest":"accepted","offer_code":"EXTENSION_POST_COSECHA","commitment_signal":"strong","sentiment":"POSITIVE","sentiment_score":0.4,"confidence":0.9}},
 {"r":"agent","s":"CONFIRMACION","t":"Confirmo: solicitud para pagar {monto} el {nueva_fecha}, sujeta a aprobación. ¿La registramos?"},
 {"r":"customer","t":"Sí, regístrela.","sc":{"confirmation_given":"yes","commitment_signal":"explicit","sentiment":"POSITIVE","sentiment_score":0.4,"confidence":0.95}},
 {"r":"agent","s":"SIGUIENTE_PASO","t":"Solicitud registrada con el código {recibo}. Le confirmaremos por WhatsApp en un máximo de 24 horas hábiles.","commit":true},
 {"r":"customer","t":"Gracias, Dios le bendiga.","sc":{"sentiment":"POSITIVE","sentiment_score":0.7,"confidence":0.9}},
 {"r":"agent","s":"CIERRE","t":"A usted, {nombre}. Que tenga buena cosecha."}]},

"H_NO_CONTESTA": {"outcome":"NO_ANSWER","offer":null,"lines":[]},

"M_NUEVA_FECHA": {"outcome":"DATE_EXTENSION_AGREED","offer":"EXTENSION_15","handoff":"SEND_COMMITMENT_SUMMARY","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, dígame.","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.6,"confidence":0.9}},
 {"r":"agent","s":"CONTEXTO","t":"Gracias. Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Le funciona pagar en esa fecha?"},
 {"r":"customer","t":"Esa fecha no me cuadra, me pagan hasta el otro viernes.","sc":{"intent":"NEEDS_ALTERNATIVE_DATE","payment_capacity":"full","difficulty_reason":"income_delay","extracted_date_text":"el otro viernes","sentiment":"CONCERNED","sentiment_score":-0.1,"engagement":0.7,"confidence":0.9}},
 {"r":"agent","s":"PROPUESTA","t":"Podemos mover su cuota de {monto} al {nueva_fecha}, sin recargo si paga ese día. ¿Le funciona?","offer_presented":true},
 {"r":"customer","t":"Sí, así sí.","sc":{"offer_interest":"accepted","offer_code":"EXTENSION_15","commitment_signal":"explicit","sentiment":"POSITIVE","sentiment_score":0.4,"confidence":0.92}},
 {"r":"agent","s":"CONFIRMACION","t":"Confirmo: pago de {monto} el {nueva_fecha}. ¿Lo registramos?"},
 {"r":"customer","t":"Sí, por favor.","sc":{"confirmation_given":"yes","sentiment":"POSITIVE","sentiment_score":0.4,"confidence":0.95}},
 {"r":"agent","s":"SIGUIENTE_PASO","t":"Quedó registrado con el código {recibo}. Le recordaré por WhatsApp un día antes.","commit":true},
 {"r":"customer","t":"Perfecto, gracias.","sc":{"accepts_whatsapp_followup":"yes","sentiment":"POSITIVE","sentiment_score":0.5,"confidence":0.9}}]},

"I_PARCIAL": {"outcome":"PARTIAL_PAYMENT_AGREED","offer":"PAGO_PARCIAL_50","link":true,"handoff":"SEND_PAYMENT_LINK","lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, soy yo.","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":0,"engagement":0.6,"confidence":0.95}},
 {"r":"agent","s":"CONTEXTO","t":"Gracias. Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Tiene previsto pagarla completa?"},
 {"r":"customer","t":"Completa no creo, solo tengo una parte.","sc":{"intent":"FINANCIAL_DIFFICULTY","payment_capacity":"partial","difficulty_reason":"unexpected_expense","sentiment":"CONCERNED","sentiment_score":-0.2,"engagement":0.7,"confidence":0.88}},
 {"r":"agent","s":"PROPUESTA","t":"Puede pagar {monto_parcial} ahora y el saldo de {saldo} a más tardar el {nueva_fecha}, sin recargo.","offer_presented":true,"interrupt_voice":"Puede pagar {monto_parcial} ahora y el saldo"},
 {"r":"customer","t":"Espere, ¿cuánto sería el saldo?","sc":{"intent":"ASKS_QUESTION","comprehension":0.4,"offer_interest":"interested","sentiment":"NEUTRAL","sentiment_score":0,"confidence":0.85}},
 {"r":"agent","s":"PROPUESTA","t":"Claro: {monto_parcial} ahora y los {saldo} restantes a más tardar el {nueva_fecha}. ¿Le funciona?","offer_presented":true},
 {"r":"customer","t":"Ah, ok. Sí, así sí puedo.","sc":{"offer_interest":"accepted","offer_code":"PAGO_PARCIAL_50","commitment_signal":"strong","comprehension":0.9,"sentiment":"POSITIVE","sentiment_score":0.3,"confidence":0.9}},
 {"r":"agent","s":"CONFIRMACION","t":"Confirmo: {monto_parcial} hoy y {saldo} a más tardar el {nueva_fecha}. ¿Lo registramos?"},
 {"r":"customer","t":"Sí.","sc":{"confirmation_given":"yes","commitment_signal":"explicit","sentiment":"NEUTRAL","sentiment_score":0.2,"confidence":0.9}},
 {"r":"agent","s":"SIGUIENTE_PASO","t":"Quedó registrado con el código {recibo}. Le envío por WhatsApp el link para el primer pago.","commit":true},
 {"r":"customer","t":"Va, gracias.","sc":{"accepts_whatsapp_followup":"yes","sentiment":"POSITIVE","sentiment_score":0.3,"confidence":0.9}}]},

"J_TERCERO": {"outcome":"WRONG_PERSON","offer":null,"lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"No, no está. Yo soy la esposa.","sc":{"wrong_person":"yes","intent":"WRONG_PERSON","sentiment":"NEUTRAL","sentiment_score":0,"confidence":0.95}},
 {"r":"agent","s":"CIERRE_TERCERO","t":"Gracias por atenderme. Intentaremos comunicarnos más tarde. Que tenga buen día."}]},

"K_WA_PAGO": {"outcome":"PAID_DURING_CONTACT","offer":"PAGO_TOTAL","link":true,"paid_in_chat":true,"lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí, soy yo","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":0.1,"engagement":0.6,"confidence":0.95}},
 {"r":"agent","s":"CONTEXTO","t":"Gracias. Le escribo con anticipación: su cuota de {monto} vence el {fecha}. ¿Desea que le envíe un link seguro para pagarla desde su celular?"},
 {"r":"customer","t":"Sí, mándelo de una vez","sc":{"intent":"WILL_PAY","payment_capacity":"full","commitment_signal":"explicit","confirmation_given":"yes","offer_code":"PAGO_TOTAL","sentiment":"POSITIVE","sentiment_score":0.5,"engagement":0.9,"confidence":0.93}},
 {"r":"agent","s":"CONFIRMACION","t":"Listo ✅ Su link de pago por {monto}: {link} · Código {recibo}.","commit":true},
 {"r":"customer","t":"Ya pagué, gracias","sc":{"already_paid_claim":"yes","sentiment":"POSITIVE","sentiment_score":0.7,"confidence":0.95}},
 {"r":"agent","s":"CIERRE","t":"¡Recibido, {nombre}! Su pago quedó aplicado. Gracias por mantener su récord al día."}]},

"L_NO_CONTACTAR": {"outcome":"DO_NOT_CONTACT","offer":null,"opt_out":true,"lines":[
 {"r":"agent","s":"APERTURA","t":"{apertura}"},
 {"r":"customer","t":"Sí.","sc":{"identity_confirmed":"yes","sentiment":"NEUTRAL","sentiment_score":-0.1,"confidence":0.8}},
 {"r":"agent","s":"CONTEXTO","t":"Le contacto con anticipación: su cuota de {monto} vence el {fecha}. ¿Tiene previsto pagarla en esa fecha?"},
 {"r":"customer","t":"Por favor no me vuelvan a llamar.","sc":{"do_not_contact_request":"yes","sentiment":"FRUSTRATED","sentiment_score":-0.5,"resistance":0.8,"confidence":0.95}},
 {"r":"agent","s":"NEGATIVA_RESPETADA","t":"Entendido, {nombre}. Registramos su solicitud y no le volveremos a contactar por este medio. Que tenga buen día."}]}
}$j$::jsonb
$seed$;

create or replace function seed_pick_archetype(p_profile text, p_income text, p_key text) returns text
language plpgsql immutable as $seed$
declare
  v_w    jsonb;
  v_u    numeric := drand(p_key)::numeric * 100;
  v_acc  numeric := 0;
  r      record;
  v_out  text;
begin
  v_w := case p_profile
    when 'EXCELENTE'  then '{"A_COOPERATIVO":55,"K_WA_PAGO":20,"B_EVASIVO":12,"J_TERCERO":6,"H_NO_CONTESTA":7}'
    when 'BUENO'      then '{"A_COOPERATIVO":38,"M_NUEVA_FECHA":10,"K_WA_PAGO":15,"B_EVASIVO":15,"I_PARCIAL":5,"J_TERCERO":5,"H_NO_CONTESTA":8,"E_PIDE_HUMANO":4}'
    when 'PREVENTIVO' then '{"A_COOPERATIVO":18,"M_NUEVA_FECHA":12,"B_EVASIVO":13,"C_DIFICULTAD":15,"I_PARCIAL":12,"F_NEGATIVA":5,"H_NO_CONTESTA":10,"D_MOLESTO":5,"J_TERCERO":5,"E_PIDE_HUMANO":3,"L_NO_CONTACTAR":2}'
    when 'ALTO'       then '{"C_DIFICULTAD":22,"I_PARCIAL":14,"M_NUEVA_FECHA":8,"B_EVASIVO":10,"A_COOPERATIVO":8,"D_MOLESTO":10,"F_NEGATIVA":8,"H_NO_CONTESTA":10,"E_PIDE_HUMANO":6,"L_NO_CONTACTAR":3}'
    else                   '{"C_DIFICULTAD":20,"D_MOLESTO":15,"F_NEGATIVA":14,"E_PIDE_HUMANO":9,"H_NO_CONTESTA":15,"I_PARCIAL":10,"B_EVASIVO":12,"L_NO_CONTACTAR":5}'
  end::jsonb;
  for r in select key, value from jsonb_each(v_w) order by key loop
    v_acc := v_acc + jnum(r.value);
    if v_u < v_acc then v_out := r.key; exit; end if;
  end loop;
  v_out := coalesce(v_out, 'A_COOPERATIVO');
  if v_out = 'C_DIFICULTAD' and p_income = 'agricultor' then v_out := 'G_AGRO'; end if;
  return v_out;
end $seed$;

-- ─── 12 personajes de la demo (IDs fijos) ──────────────────────────────────
create or replace function seed_personas() returns int
language plpgsql as $seed$
declare
  s  jsonb;
  c  jsonb;
  n  int := 0;
begin
  for s in select * from jsonb_array_elements($j$[
  {"id":"00000000-0000-4000-8000-000000000001","code":"DEMO-001","first":"Carlos","last":"Martínez Aguilar","gender":"M","age":38,
   "dept":"San Salvador","city":"Soyapango","zone":"urbana","segment":"MASIVO","income_type":"asalariado","income":780,"occupation":"Técnico de mantenimiento",
   "channel":"voice","window":"tarde","profile":"ALTO","persona":true,"phone":"+50300000001","email":"demo001@correo-demo.test",
   "notes":"ESCENARIO DORADO DE VOZ. Riesgo alto, vence en 2 días, salario atrasado y caída de saldo. Incumplió un compromiso hace 3 meses. Reglas: Riesgo alto + Historial de atrasos + Compromiso roto.",
   "loan":{"product":"PERSONAL","name":"Crédito Personal","purpose":"Mejoras de vivienda","principal":6500,"rate":0.18,"term":48,"months_paid":14,"next_due_offset":2,
           "late_pattern":[0,6,0,0,12,0,22,0,8,0,15,9]},
   "signals":[["SALARY_DEPOSIT_DELAYED","medium","Depósito de planilla llegó 9 días tarde en agosto",12],
              ["ACCOUNT_BALANCE_DROP","high","Saldo promedio de cuenta bajó 68% en 30 días",6],
              ["APP_ACTIVITY_DROP","low","Sin ingresos a la app en 24 días",4]],
   "contacts":[{"days_ago":95,"archetype":"I_PARCIAL","channel":"voice","kept":false}]},

  {"id":"00000000-0000-4000-8000-000000000002","code":"DEMO-002","first":"María","last":"López Portillo","gender":"F","age":52,
   "dept":"Santa Ana","city":"Chalchuapa","zone":"rural","segment":"AGRO","income_type":"agricultor","income":650,"occupation":"Productora de café",
   "agro":{"crop":"café","hectares":3.5,"harvest_months":[11,12,1,2],"dry_corridor":false,"cooperative":"Cooperativa Los Naranjos (ficticia)"},
   "channel":"voice","window":"manana","profile":"PREVENTIVO","persona":true,"phone":"+50300000002","email":"demo002@correo-demo.test",
   "notes":"PRODUCTORA AGRÍCOLA. Cafetalera en temporada baja; cosecha desde noviembre. Oferta clave: diferir hasta la cosecha (requiere aprobación humana).",
   "loan":{"product":"AGRICOLA_AVIO","name":"Crédito Agrícola de Avío","purpose":"Fertilización y mantenimiento de cafetal","principal":8000,"rate":0.13,"term":24,"months_paid":10,"next_due_offset":6,
           "late_pattern":[0,0,3,0,0,7,0,0,0,5]},
   "signals":[["HARVEST_LOW_SEASON","medium","Cosecha de café inicia en noviembre",20],
              ["ACCOUNT_BALANCE_DROP","medium","Saldo promedio bajó 41% en 30 días",9]]},

  {"id":"00000000-0000-4000-8000-000000000003","code":"DEMO-003","first":"José","last":"Hernández Rivas","gender":"M","age":45,
   "dept":"La Libertad","city":"Santa Tecla","zone":"urbana","segment":"PREFERENTE","income_type":"asalariado","income":1350,"occupation":"Contador",
   "channel":"whatsapp","window":"noche","profile":"BUENO","persona":true,"phone":"+50300000003","email":"demo003@correo-demo.test",
   "notes":"BUEN PAGADOR · DEMO WHATSAPP. Recordatorio amable, link de pago, cero negociación.",
   "loan":{"product":"PERSONAL","name":"Crédito Personal","purpose":"Estudios","principal":4000,"rate":0.15,"term":36,"months_paid":20,"next_due_offset":4,
           "late_pattern":[0,0,0,0,0,2,0,0,0,0,0,0]},
   "signals":[]},

  {"id":"00000000-0000-4000-8000-000000000004","code":"DEMO-004","first":"Ana","last":"Rivera Mejía","gender":"F","age":41,
   "dept":"San Miguel","city":"San Miguel","zone":"urbana","segment":"MASIVO","income_type":"asalariado","income":900,"occupation":"Operaria textil",
   "channel":"voice","window":"manana","profile":"ALTO","persona":true,"phone":"+50300000004","email":"demo004@correo-demo.test",
   "notes":"DIFICULTAD ECONÓMICA. Perdió su empleo; lo contó en agencia. Playbook de escucha empática; plan extendido requiere aprobación.",
   "loan":{"product":"PERSONAL","name":"Crédito Personal","purpose":"Consolidación de deudas","principal":5000,"rate":0.19,"term":36,"months_paid":16,"next_due_offset":5,
           "late_pattern":[0,0,0,4,0,0,0,0,6,0,0,10]},
   "signals":[["JOB_LOSS_REPORTED","high","Baja en planilla reportada por el empleador",15,"planilla"],
              ["CUSTOMER_REPORTED_DIFFICULTY","high","Comentó en agencia que perdió su empleo",8,"agencia"]]},

  {"id":"00000000-0000-4000-8000-000000000005","code":"DEMO-005","first":"Luis","last":"Ramírez Chávez","gender":"M","age":50,
   "dept":"Sonsonate","city":"Izalco","zone":"urbana","segment":"PYME","income_type":"comerciante","income":1100,"occupation":"Dueño de ferretería",
   "channel":"whatsapp","window":"tarde","profile":"ALTO","persona":true,"phone":"+50300000005","email":"demo005@correo-demo.test",
   "notes":"CLIENTE MOLESTO. Incumplió compromiso hace 2 meses y hace 12 días se molestó y pidió asesor. Regla de compromiso roto: límites más cortos y tono firme-respetuoso.",
   "loan":{"product":"PYME","name":"Crédito PYME Capital de Trabajo","purpose":"Inventario","principal":15000,"rate":0.16,"term":48,"months_paid":22,"next_due_offset":6,
           "late_pattern":[5,0,12,0,8,18,0,10,0,14,0,9],"partial_idx":[5,9]},
   "signals":[["ACCOUNT_BALANCE_DROP","medium","Ventas depositadas bajaron 35%",10]],
   "contacts":[{"days_ago":62,"archetype":"C_DIFICULTAD","channel":"whatsapp","kept":false},
               {"days_ago":12,"archetype":"D_MOLESTO","channel":"voice"}]},

  {"id":"00000000-0000-4000-8000-000000000006","code":"DEMO-006","first":"Sofía","last":"Castillo Guevara","gender":"F","age":29,
   "dept":"San Salvador","city":"Mejicanos","zone":"urbana","segment":"MASIVO","income_type":"asalariado","income":620,"occupation":"Asistente administrativa",
   "channel":"whatsapp","window":"noche","profile":"PREVENTIVO","persona":true,"phone":"+50300000006","email":"demo006@correo-demo.test",
   "notes":"MORA TEMPRANA. Cuota vencida hace 4 días. Oferta: eliminar recargo si paga en 3 días.",
   "loan":{"product":"MICROCREDITO","name":"Microcrédito Emprende","purpose":"Venta de ropa por catálogo","principal":1200,"rate":0.24,"term":12,"months_paid":6,"next_due_offset":-4,
           "late_pattern":[0,3,0,0,5,0]},
   "signals":[["APP_ACTIVITY_DROP","low","Sin ingresos a la app en 15 días",3]]},

  {"id":"00000000-0000-4000-8000-000000000007","code":"DEMO-007","first":"Pedro","last":"Flores Argueta","gender":"M","age":58,
   "dept":"San Miguel","city":"Chinameca","zone":"rural","segment":"AGRO","income_type":"agricultor","income":480,"occupation":"Productor de maíz y frijol",
   "agro":{"crop":"maíz","hectares":2,"harvest_months":[8,9,11,12],"dry_corridor":true,"cooperative":null},
   "channel":"voice","window":"manana","profile":"ALTO","persona":true,"phone":"+50300000007","email":"demo007@correo-demo.test",
   "notes":"CORREDOR SECO. Déficit de lluvia afectó la siembra. Escenario de ruido de fondo (falsas interrupciones).",
   "loan":{"product":"AGRICOLA_AVIO","name":"Crédito Agrícola de Avío","purpose":"Siembra de primera","principal":3500,"rate":0.12,"term":18,"months_paid":9,"next_due_offset":9,
           "late_pattern":[0,0,5,0,9,0,0,14,0]},
   "signals":[["CLIMATE_EVENT","high","Déficit de lluvia en el corredor seco afectó la siembra de primera",18,"clima"],
              ["ACCOUNT_BALANCE_DROP","medium","Saldo promedio bajó 50% en 30 días",7]]},

  {"id":"00000000-0000-4000-8000-000000000008","code":"DEMO-008","first":"Rosa","last":"Aguilar Menjívar","gender":"F","age":47,
   "dept":"Usulután","city":"Jiquilisco","zone":"rural","segment":"MASIVO","income_type":"remesas","income":450,"occupation":"Ama de casa",
   "channel":"whatsapp","window":"tarde","profile":"PREVENTIVO","persona":true,"phone":"+50300000008","email":"demo008@correo-demo.test",
   "notes":"BLOQUEADA POR REGLA. Tiene una disputa abierta: el sistema NO la contacta aunque tenga riesgo. Muestra que las reglas protegen.",
   "loan":{"product":"PERSONAL","name":"Crédito Personal","purpose":"Gastos médicos","principal":3000,"rate":0.2,"term":24,"months_paid":11,"next_due_offset":2,
           "late_pattern":[0,0,4,0,0,0,6,0,0,0,3]},
   "signals":[["OPEN_DISPUTE","high","Reclamo abierto por cargo duplicado en agosto",14,"agencia"],
              ["REMITTANCE_DECREASE","medium","Remesas bajaron 30% frente a su promedio",20]]},

  {"id":"00000000-0000-4000-8000-000000000009","code":"DEMO-009","first":"Miguel","last":"Portillo Cruz","gender":"M","age":35,
   "dept":"La Paz","city":"Zacatecoluca","zone":"urbana","segment":"MASIVO","income_type":"independiente","income":700,"occupation":"Mecánico independiente",
   "channel":"voice","window":"tarde","profile":"ALTO","persona":true,"control":true,"phone":"+50300000009","email":"demo009@correo-demo.test",
   "notes":"GRUPO DE CONTROL. Riesgo alto pero NUNCA se contacta: permite medir mora evitada contra un contrafactual.",
   "loan":{"product":"PERSONAL","name":"Crédito Personal","purpose":"Herramientas","principal":4500,"rate":0.2,"term":36,"months_paid":13,"next_due_offset":3,
           "late_pattern":[0,8,0,11,0,0,16,0,7,0,12,0]},
   "signals":[["ACCOUNT_BALANCE_DROP","high","Saldo promedio bajó 60%",5],["MULTIPLE_CREDIT_INQUIRIES","medium","3 consultas en otras entidades en 30 días",11,"buro"]]},

  {"id":"00000000-0000-4000-8000-000000000010","code":"DEMO-010","first":"Carmen","last":"Mejía Bonilla","gender":"F","age":44,
   "dept":"La Libertad","city":"Antiguo Cuscatlán","zone":"urbana","segment":"PREMIUM","income_type":"asalariado","income":3200,"occupation":"Gerente de operaciones",
   "channel":"email","window":"manana","profile":"EXCELENTE","persona":true,"phone":"+50300000010","email":"demo010@correo-demo.test",
   "notes":"PREMIUM, RIESGO BAJO. Hoy recibe recordatorio por WhatsApp. Si en la web se ACTIVA la regla R-PREMIUM, cambia a email. Demo del interruptor de reglas.",
   "loan":{"product":"VIVIENDA","name":"Crédito Hipotecario","purpose":"Compra de vivienda","principal":65000,"rate":0.095,"term":240,"months_paid":26,"next_due_offset":4,
           "late_pattern":[]},
   "signals":[]},

  {"id":"00000000-0000-4000-8000-000000000011","code":"DEMO-011","first":"Jorge","last":"Alvarado Molina","gender":"M","age":62,
   "dept":"Chalatenango","city":"La Palma","zone":"rural","segment":"AGRO","income_type":"agricultor","income":520,"occupation":"Productor de hortalizas",
   "agro":{"crop":"hortalizas","hectares":1.2,"harvest_months":[1,2,3,4,5,6,7,8,9,10,11,12],"dry_corridor":false,"cooperative":null},
   "channel":"voice","window":"manana","profile":"PREVENTIVO","persona":true,"opted_out_days_ago":20,"opt_out_reason":"Pidió no ser contactado por teléfono",
   "phone":"+50300000011","email":"demo011@correo-demo.test",
   "notes":"PIDIÓ NO SER CONTACTADO. Bloqueado por regla aunque tenga cuota próxima.",
   "loan":{"product":"MICROCREDITO","name":"Microcrédito Agro","purpose":"Sistema de riego por goteo","principal":2000,"rate":0.22,"term":18,"months_paid":8,"next_due_offset":5,
           "late_pattern":[0,0,6,0,0,4,0,8]},
   "signals":[]},

  {"id":"00000000-0000-4000-8000-000000000012","code":"DEMO-012","first":"Elena","last":"Guzmán Orellana","gender":"F","age":33,
   "dept":"Santa Ana","city":"Santa Ana","zone":"urbana","segment":"MASIVO","income_type":"comerciante","income":850,"occupation":"Vendedora en mercado",
   "channel":"whatsapp","window":"tarde","profile":"PREVENTIVO","persona":true,"phone":"+50300000012","email":"demo012@correo-demo.test",
   "notes":"EVASIVA · WHATSAPP. Atrasos frecuentes pero cortos; vence en 2 días. Escenarios: evasivo, negativa x2, silencio.",
   "loan":{"product":"MICROCREDITO","name":"Microcrédito Emprende","purpose":"Mercadería","principal":2500,"rate":0.24,"term":18,"months_paid":12,"next_due_offset":2,
           "late_pattern":[0,0,4,0,0,7,0,0,3,0,0,5]},
   "signals":[["APP_ACTIVITY_DROP","low","Sin ingresos a la app en 18 días",6]]}
  ]$j$::jsonb) loop
    perform seed_insert_customer(s);
    n := n + 1;
    for c in select * from jsonb_array_elements(coalesce(s->'contacts', '[]')) loop
      insert into _seed_contacts (customer_code, profile, archetype, channel, kept, days_ago)
      values (s->>'code', s->>'profile', c->>'archetype', c->>'channel', jbool(c->'kept'), jnum(c->'days_ago')::int);
    end loop;
  end loop;
  return n;
end $seed$;

-- ─── Clientes generados ────────────────────────────────────────────────────
create or replace function seed_customers(p_count int default 150) returns int
language plpgsql as $seed$
declare
  v_today   date := sv_today();
  v_fem     text[] := array['María','Ana','Rosa','Carmen','Sofía','Elena','Gloria','Marta','Patricia','Sandra','Claudia','Verónica','Karla','Silvia','Blanca','Yesenia','Lorena','Reina','Delmy','Evelyn','Fátima','Brenda','Jacqueline','Xiomara','Iris'];
  v_masc    text[] := array['Carlos','José','Luis','Juan','Miguel','Jorge','Pedro','Mario','Francisco','Roberto','Óscar','Manuel','Ricardo','Julio','Salvador','René','Mauricio','Edwin','Wilfredo','Nelson','Douglas','Fredy','Rafael','Ernesto','Alfredo'];
  v_sur     text[] := array['Hernández','Martínez','López','García','Rodríguez','Ramírez','Flores','Rivera','Cruz','Aguilar','Mejía','Portillo','Guzmán','Alvarado','Castillo','Romero','Sánchez','Chávez','Menjívar','Orellana','Ayala','Argueta','Quintanilla','Bonilla','Escobar','Villalta','Guevara','Fuentes','Rivas','Molina','Campos','Deras','Cañas','Mendoza','Lemus'];
  v_depts   jsonb := $j$[
    {"d":"San Salvador","c":["San Salvador","Soyapango","Mejicanos","Apopa","Ilopango"],"dry":false,"crops":["hortalizas"]},
    {"d":"La Libertad","c":["Santa Tecla","Antiguo Cuscatlán","Quezaltepeque","Zaragoza","Colón"],"dry":false,"crops":["café","hortalizas","caña de azúcar"]},
    {"d":"Santa Ana","c":["Santa Ana","Chalchuapa","Metapán","Coatepeque"],"dry":false,"crops":["café","caña de azúcar","maíz"]},
    {"d":"San Miguel","c":["San Miguel","Chinameca","Ciudad Barrios","Moncagua"],"dry":true,"crops":["maíz","frijol","ganadería"]},
    {"d":"Usulután","c":["Usulután","Jiquilisco","Santiago de María","Berlín"],"dry":true,"crops":["café","caña de azúcar","ganadería"]},
    {"d":"Sonsonate","c":["Sonsonate","Izalco","Juayúa","Nahuizalco"],"dry":false,"crops":["café","caña de azúcar"]},
    {"d":"Ahuachapán","c":["Ahuachapán","Atiquizaya","Tacuba","Apaneca"],"dry":false,"crops":["café","hortalizas"]},
    {"d":"La Paz","c":["Zacatecoluca","Olocuilta","San Luis Talpa"],"dry":false,"crops":["caña de azúcar","maíz"]},
    {"d":"Chalatenango","c":["Chalatenango","Nueva Concepción","La Palma"],"dry":false,"crops":["hortalizas","maíz","frijol"]},
    {"d":"Cuscatlán","c":["Cojutepeque","Suchitoto"],"dry":false,"crops":["hortalizas","maíz"]},
    {"d":"La Unión","c":["La Unión","Santa Rosa de Lima","Conchagua"],"dry":true,"crops":["maíz","frijol","ganadería"]},
    {"d":"Morazán","c":["San Francisco Gotera","Perquín","Jocoaitique"],"dry":true,"crops":["maíz","frijol","café"]},
    {"d":"San Vicente","c":["San Vicente","Tecoluca"],"dry":false,"crops":["caña de azúcar","maíz"]},
    {"d":"Cabañas","c":["Sensuntepeque","Ilobasco"],"dry":false,"crops":["maíz","frijol","ganadería"]}]$j$;
  v_harvest jsonb := '{"café":[11,12,1,2],"caña de azúcar":[11,12,1,2,3,4],"maíz":[8,9,11,12],"frijol":[10,11,12],"hortalizas":[1,2,3,4,5,6,7,8,9,10,11,12],"ganadería":[1,2,3,4,5,6,7,8,9,10,11,12]}';
  i int; j int;
  k text; code text; prof text; gender text; inc_type text; product text; pname text; purpose text; seg text; crop text; chan text;
  dep jsonb; agro jsonb; sig jsonb; pat jsonb; parts jsonb; spec jsonb;
  u numeric; income numeric; principal numeric; rate numeric; term int; r numeric; inst numeric;
  mpaid int; off int; base numeric; p numeric; late int; lo int; hi int; keep numeric;
  due date; ctrl boolean; treated boolean; arche text; kept boolean; is_risk boolean;
begin
  for i in 1 .. p_count loop
    k    := 'c' || i;
    code := 'C' || lpad(i::text, 4, '0');
    u    := drand(k || ':profile');
    prof := case when u < .25 then 'EXCELENTE' when u < .50 then 'BUENO' when u < .70 then 'PREVENTIVO'
                 when u < .88 then 'ALTO' else 'CRITICO' end;
    is_risk := prof in ('PREVENTIVO','ALTO','CRITICO');
    gender := case when drand(k || ':g') < .5 then 'F' else 'M' end;
    dep := v_depts -> dint(k || ':dep', 0, jsonb_array_length(v_depts) - 1);

    u := drand(k || ':inc');
    inc_type := case when u < .20 then 'agricultor' when u < .60 then 'asalariado' when u < .75 then 'comerciante'
                     when u < .87 then 'remesas' else 'independiente' end;
    income := round(case inc_type when 'asalariado' then dnum(k||':$',450,1800) when 'agricultor' then dnum(k||':$',300,1400)
                                  when 'comerciante' then dnum(k||':$',500,2600) when 'remesas' then dnum(k||':$',250,700)
                                  else dnum(k||':$',400,1600) end);
    u := drand(k || ':prod');
    product := case inc_type
      when 'agricultor'  then case when u < .8 then 'AGRICOLA_AVIO' else 'MICROCREDITO' end
      when 'asalariado'  then case when u < .7 then 'PERSONAL' when u < .9 then 'VIVIENDA' else 'MICROCREDITO' end
      when 'comerciante' then case when u < .5 then 'PYME' else 'MICROCREDITO' end
      else case when u < .6 then 'PERSONAL' else 'MICROCREDITO' end end;
    pname := case product when 'PERSONAL' then 'Crédito Personal' when 'AGRICOLA_AVIO' then 'Crédito Agrícola de Avío'
                          when 'PYME' then 'Crédito PYME Capital de Trabajo' when 'MICROCREDITO' then 'Microcrédito Emprende'
                          else 'Crédito Hipotecario' end;
    purpose := dpick(k || ':purp', case product
      when 'PERSONAL' then array['Mejoras de vivienda','Estudios','Consolidación de deudas','Gastos médicos','Compra de electrodomésticos']
      when 'AGRICOLA_AVIO' then array['Siembra de primera','Fertilización','Compra de semilla','Mantenimiento de cultivo']
      when 'PYME' then array['Inventario','Capital de trabajo','Compra de equipo']
      when 'MICROCREDITO' then array['Mercadería','Venta por catálogo','Pequeño comercio','Herramientas']
      else array['Compra de vivienda','Construcción'] end);
    principal := case product when 'PERSONAL' then dnum(k||':P',1500,12000) when 'AGRICOLA_AVIO' then dnum(k||':P',2000,25000)
                              when 'PYME' then dnum(k||':P',5000,40000) when 'MICROCREDITO' then dnum(k||':P',300,3000)
                              else dnum(k||':P',25000,90000) end;
    rate := round(case product when 'PERSONAL' then dnum(k||':R',.14,.22) when 'AGRICOLA_AVIO' then dnum(k||':R',.10,.15)
                               when 'PYME' then dnum(k||':R',.13,.19) when 'MICROCREDITO' then dnum(k||':R',.20,.28)
                               else dnum(k||':R',.08,.11) end, 4);
    term := case product when 'PERSONAL' then dpick(k||':T', array['24','36','48','60'])::int when 'AGRICOLA_AVIO' then dpick(k||':T', array['12','18','24'])::int
                         when 'PYME' then dpick(k||':T', array['36','48','60'])::int when 'MICROCREDITO' then dpick(k||':T', array['6','12','18'])::int
                         else dpick(k||':T', array['180','240'])::int end;
    r := rate / 12;
    inst := principal * r / (1 - power(1 + r, -term));
    if inst > income * 0.4 then
      principal := income * 0.4 * (1 - power(1 + r, -term)) / r;
    end if;
    principal := round(principal, -1);

    seg := case when product = 'PYME' then 'PYME' when inc_type = 'agricultor' then 'AGRO'
                when inc_type = 'asalariado' and income > 1500 and drand(k||':prem') < .5 then 'PREMIUM'
                when drand(k||':pref') < .2 then 'PREFERENTE' else 'MASIVO' end;

    agro := null;
    if inc_type = 'agricultor' then
      crop := (dep->'crops') ->> dint(k||':crop', 0, jsonb_array_length(dep->'crops') - 1);
      agro := jsonb_build_object('crop', crop, 'hectares', round(dnum(k||':ha', .5, 6), 1),
                                 'harvest_months', v_harvest -> crop, 'dry_corridor', (dep->>'dry')::boolean,
                                 'cooperative', null);
    end if;

    mpaid := dint(k || ':mp', 6, least(term - 2, 26));
    if prof = 'CRITICO' and drand(k||':od') < .45 then off := -dint(k||':dpd', 1, 20);
    elsif prof = 'ALTO' and drand(k||':od') < .12 then off := -dint(k||':dpd', 1, 10);
    elsif is_risk and drand(k||':soon') < .7 then off := dint(k||':off', 0, 8);
    else off := dint(k||':off', 1, 30); end if;

    ctrl := is_risk and drand(k||':ctrl') < .30;

    base := case prof when 'EXCELENTE' then .02 when 'BUENO' then .10 when 'PREVENTIVO' then .28 when 'ALTO' then .42 else .58 end;
    lo   := case prof when 'EXCELENTE' then 1 when 'BUENO' then 1 when 'PREVENTIVO' then 2 when 'ALTO' then 4 else 8 end;
    hi   := case prof when 'EXCELENTE' then 3 when 'BUENO' then 7 when 'PREVENTIVO' then 18 when 'ALTO' then 30 else 45 end;
    keep := case prof when 'EXCELENTE' then .97 when 'BUENO' then .92 when 'PREVENTIVO' then .82 when 'ALTO' then .72 else .55 end;

    pat := '[]'; parts := '[]';
    for j in 1 .. mpaid loop
      due := ((v_today + off) - make_interval(months => mpaid + 1 - j))::date;
      p := base * case when due > v_today - 180 and prof in ('ALTO','CRITICO') then 1.3
                       when due > v_today - 180 and prof = 'PREVENTIVO' then 1.15 else 1 end;
      treated := not ctrl and due between v_today - 45 and v_today - 1 and (
                   (is_risk and drand(k||':tr:'||j) < .8) or (prof = 'BUENO' and drand(k||':tr:'||j) < .25)
                   or (prof = 'EXCELENTE' and drand(k||':tr:'||j) < .10));
      if treated then
        arche := seed_pick_archetype(prof, inc_type, k || ':a:' || j);
        chan  := case when drand(k||':chp:'||j) < .6 then (case when drand(k||':pc') < .7 then 'whatsapp' else 'voice' end)
                      when drand(k||':chr:'||j) < .5 then 'voice' else 'whatsapp' end;
        if arche = 'K_WA_PAGO' then chan := 'whatsapp'; end if;

        kept := null;
        if arche in ('A_COOPERATIVO','K_WA_PAGO','C_DIFICULTAD','I_PARCIAL','G_AGRO','M_NUEVA_FECHA') then
          kept := drand(k||':kept:'||j) < keep;
          late := case when kept then (case arche when 'C_DIFICULTAD' then dint(k||':cl:'||j, 3, 12)
                                                  when 'M_NUEVA_FECHA' then dint(k||':cl:'||j, 5, 14)
                                                  when 'I_PARCIAL' then dint(k||':cl:'||j, 2, 10) else 0 end)
                       else dint(k||':bl:'||j, 10, 35) end;
        else
          -- supuesto de simulación: recibir info por WhatsApp o atención de asesor reduce el atraso
          late := case when drand(k||':l:'||j) < p * (case when arche in ('B_EVASIVO','D_MOLESTO','E_PIDE_HUMANO') then 0.7 else 1.0 end)
                       then dint(k||':ld:'||j, lo, hi) else 0 end;
        end if;
        insert into _seed_contacts (customer_code, due_date, profile, archetype, channel, kept, days_before)
        values (code, due, prof, arche, chan, kept, dint(k||':db:'||j, 2, 7));
      else
        late := case when drand(k||':l:'||j) < p then dint(k||':ld:'||j, lo, hi) else 0 end;
      end if;
      if late > 2 and prof in ('ALTO','CRITICO') and drand(k||':pp:'||j) < .15 then
        parts := parts || to_jsonb(j - 1);
      end if;
      pat := pat || to_jsonb(late);
    end loop;

    -- señales
    sig := '[]';
    if inc_type = 'asalariado' and drand(k||':s1') < (case prof when 'ALTO' then .4 when 'CRITICO' then .5 when 'PREVENTIVO' then .2 else .03 end) then
      sig := sig || jsonb_build_array(jsonb_build_array('SALARY_DEPOSIT_DELAYED','medium', format('Depósito de planilla llegó %s días tarde', dint(k||':s1d',4,12)), dint(k||':s1a',3,20)));
    end if;
    if drand(k||':s2') < (case prof when 'CRITICO' then .6 when 'ALTO' then .45 when 'PREVENTIVO' then .3 when 'BUENO' then .08 else .02 end) then
      sig := sig || jsonb_build_array(jsonb_build_array('ACCOUNT_BALANCE_DROP', case when prof in ('ALTO','CRITICO') then 'high' else 'medium' end,
                                                        format('Saldo promedio bajó %s%% en 30 días', dint(k||':s2d',35,80)), dint(k||':s2a',2,15)));
    end if;
    if inc_type = 'remesas' and is_risk and drand(k||':s3') < .5 then
      sig := sig || jsonb_build_array(jsonb_build_array('REMITTANCE_DECREASE','medium', format('Remesas bajaron %s%% frente a su promedio de 6 meses', dint(k||':s3d',20,55)), dint(k||':s3a',5,25)));
    end if;
    if is_risk and drand(k||':s4') < .3 then
      sig := sig || jsonb_build_array(jsonb_build_array('APP_ACTIVITY_DROP','low', format('Sin ingresos a la app en %s días', dint(k||':s4d',14,40)), dint(k||':s4a',1,10)));
    end if;
    if inc_type = 'agricultor' and crop in ('café','caña de azúcar') then
      sig := sig || jsonb_build_array(jsonb_build_array('HARVEST_LOW_SEASON','medium', format('Cosecha de %s inicia en noviembre', crop), dint(k||':s5a',10,30), 'calendario_agricola'));
    end if;
    if inc_type = 'agricultor' and (dep->>'dry')::boolean and drand(k||':s6') < .6 then
      sig := sig || jsonb_build_array(jsonb_build_array('CLIMATE_EVENT','high', 'Déficit de lluvia en el corredor seco afectó la siembra de primera', dint(k||':s6a',10,30), 'clima'));
    end if;
    if drand(k||':s7') < (case prof when 'CRITICO' then .35 when 'ALTO' then .15 else .01 end) then
      sig := sig || jsonb_build_array(jsonb_build_array('MULTIPLE_CREDIT_INQUIRIES','medium', format('%s consultas en otras entidades en 30 días', dint(k||':s7d',2,5)), dint(k||':s7a',3,25), 'buro'));
    end if;
    if prof = 'CRITICO' and inc_type = 'asalariado' and drand(k||':s8') < .12 then
      sig := sig || jsonb_build_array(jsonb_build_array('JOB_LOSS_REPORTED','high', 'Baja en planilla reportada por el empleador', dint(k||':s8a',5,30), 'planilla'));
    end if;
    if drand(k||':s9') < .015 then
      sig := sig || jsonb_build_array(jsonb_build_array('OPEN_DISPUTE','high', 'Reclamo abierto por cargo no reconocido', dint(k||':s9a',3,20), 'agencia'));
    end if;
    if drand(k||':s10') < .03 then
      sig := sig || jsonb_build_array(jsonb_build_array('CONTACT_INFO_OUTDATED','low', 'Dos intentos fallidos al número registrado', dint(k||':s10a',5,40), 'contact_center'));
    end if;

    spec := jsonb_build_object(
      'code', code, 'first', dpick(k||':fn', case gender when 'F' then v_fem else v_masc end),
      'last', dpick(k||':ln1', v_sur) || ' ' || dpick(k||':ln2', v_sur), 'gender', gender, 'age', dint(k||':age', 21, 70),
      'dept', dep->>'d', 'city', (dep->'c') ->> dint(k||':city', 0, jsonb_array_length(dep->'c') - 1),
      'zone', case when inc_type = 'agricultor' or drand(k||':zone') < .25 then 'rural' else 'urbana' end,
      'segment', seg, 'income_type', inc_type, 'income', income,
      'occupation', case inc_type when 'agricultor' then 'Productor(a) de ' || coalesce(crop, 'granos básicos')
                                  when 'asalariado' then dpick(k||':occ', array['Docente','Operario(a)','Enfermero(a)','Vendedor(a)','Motorista','Técnico(a)','Cajero(a)','Guardia de seguridad'])
                                  when 'comerciante' then dpick(k||':occ', array['Tienda de barrio','Venta en mercado','Pupusería','Ferretería','Venta de ropa'])
                                  when 'remesas' then 'Receptor(a) de remesas'
                                  else dpick(k||':occ', array['Mecánico(a)','Costurero(a)','Albañil','Estilista','Electricista']) end,
      'agro', agro,
      'channel', dpick(k||':pch', array['whatsapp','whatsapp','whatsapp','whatsapp','whatsapp','whatsapp','voice','voice','email','sms']),
      'window', dpick(k||':win', array['manana','tarde','noche']),
      'consent_voice', drand(k||':cv') < .9, 'consent_whatsapp', drand(k||':cw') < .95,
      'control', ctrl, 'profile', prof,
      'phone', '+50300' || lpad((100 + i)::text, 6, '0'), 'email', 'cliente' || i || '@correo-demo.test',
      'loan', jsonb_build_object('product', product, 'name', pname, 'purpose', purpose, 'principal', principal, 'rate', rate,
                                 'term', term, 'months_paid', mpaid, 'next_due_offset', off, 'late_pattern', pat, 'partial_idx', parts,
                                 'overdue_paid', case when off < 0 and drand(k||':odp') < .25 then round(principal * r / (1 - power(1 + r, -term)) * .3, 2) else 0 end),
      'signals', sig);
    perform seed_insert_customer(spec);
  end loop;
  return p_count;
end $seed$;

-- ─── Historial de conversaciones desde _seed_contacts ──────────────────────
create or replace function seed_history() returns int
language plpgsql as $seed$
declare
  v_today   date := sv_today();
  arcs      jsonb := seed_archetypes();
  sc        record;
  cu        customers;
  ln        loans;
  ins       installments;
  a         jsonb;
  ln_j      jsonb;
  v_conv    uuid;
  v_t       timestamptz;
  v_start   timestamptz;
  v_date    date;
  v_amt     numeric;
  v_new     date;
  v_vars    jsonb;
  v_text    text;
  v_heard   text;
  v_seq     int;
  v_eseq    int;
  v_lat     int;
  v_audio   int;
  v_msg     uuid;
  v_rule    text;
  v_pb      text;
  v_pbid    uuid;
  v_offers  jsonb;
  v_recibo  text;
  v_token   text;
  v_cm      uuid;
  v_link    uuid;
  v_status  text;
  v_arm     text;
  v_voice   text;
  v_first_s text;
  v_last_s  text;
  v_intent  text;
  v_n       int := 0;
  v_idx     int;
  v_nlines  int;
  v_next_st text;
  v_cur_st  text;
  v_risk_b  int;
  v_agent_audio int;
  v_cust_turns  int;
  v_agent_turns int;
  v_commit_amt  numeric;
  v_commit_date date;
  v_offer   offers;
begin
  for sc in select * from _seed_contacts order by customer_code, coalesce(due_date, v_today - days_ago) loop
    select * into cu from customers where customer_code = sc.customer_code;
    select * into ln from loans where customer_id = cu.id limit 1;

    if sc.days_ago is not null then
      v_date := v_today - sc.days_ago;
      select * into ins from installments where loan_id = ln.id and due_date >= v_date order by due_date limit 1;
    else
      select * into ins from installments where loan_id = ln.id and due_date = sc.due_date;
      v_date := ins.due_date - sc.days_before;
    end if;
    continue when ins.id is null;

    a := arcs -> sc.archetype;
    if sc.archetype = 'H_NO_CONTESTA' and sc.channel = 'whatsapp' then
      a := jsonb_build_object('outcome', 'ABANDONED', 'offer', null,
             'lines', jsonb_build_array(jsonb_build_object('r', 'agent', 's', 'APERTURA', 't', '{apertura}')));
    end if;
    v_amt := ins.amount_due;
    v_start := (v_date::timestamp + make_interval(hours => dint(sc.customer_code || v_date || ':hr', 9, 17),
                                                  mins => dint(sc.customer_code || v_date || ':mn', 0, 59)))
               at time zone 'America/El_Salvador';

    -- Regla/playbook plausibles para el perfil
    v_rule := case when cu.income_type = 'agricultor' then 'R-AGRO-TEMPORADA-BAJA'
                   when sc.profile in ('ALTO','CRITICO') then 'R-ALTO-PROXIMO'
                   when sc.profile = 'PREVENTIVO' and drand(sc.customer_code || 'rule') < .5 then 'R-PREVENTIVO-ATRASOS'
                   when sc.profile = 'PREVENTIVO' then 'R-SENALES-TEMPRANAS'
                   else 'R-RECORDATORIO-AMABLE' end;
    select playbook_key into v_pb from collection_rules where key = v_rule;
    select id into v_pbid from playbooks where key = v_pb;
    select coalesce(jsonb_agg(jsonb_build_object('code', o.code, 'name', o.name) order by ro.position), '[]') into v_offers
      from rule_offers ro join collection_rules r on r.id = ro.rule_id join offers o on o.id = ro.offer_id where r.key = v_rule;
    if a->>'offer' is not null and not (v_offers @> jsonb_build_array(jsonb_build_object('code', a->>'offer'))) then
      v_offers := v_offers || jsonb_build_array(jsonb_build_object('code', a->>'offer',
                    'name', (select name from offers where code = a->>'offer')));
    end if;

    v_new := case sc.archetype
      when 'C_DIFICULTAD' then v_date + 3
      when 'I_PARCIAL' then ins.due_date + 10
      when 'M_NUEVA_FECHA' then ins.due_date + 9
      when 'G_AGRO' then least(ins.due_date + 90, make_date(extract(year from ins.due_date)::int + case when extract(month from ins.due_date) > 11 then 1 else 0 end, 11, 28))
      else ins.due_date end;
    v_recibo := 'CMP-' || upper(substr(md5(sc.customer_code || v_date::text || sc.archetype), 1, 6));
    v_token  := substr(md5('link' || sc.customer_code || v_date::text), 1, 24);
    v_arm    := case when drand(sc.customer_code || v_date || ':arm') < .6 then 'A' else 'B' end;
    v_voice  := case v_arm when 'A' then 'voice.gemini-3.1-flash-live' else 'voice.gemini-2.5-flash-native-audio' end;
    v_risk_b := greatest(5, least(98, case sc.profile when 'EXCELENTE' then 12 when 'BUENO' then 32 when 'PREVENTIVO' then 62
                                                      when 'ALTO' then 81 else 92 end + dint(sc.customer_code || v_date || ':rb', -6, 6)));

    v_vars := jsonb_build_object(
      'apertura', case when sc.channel = 'whatsapp'
                       then 'Hola ' || cu.first_name || ' 👋 Le escribe el asistente digital de Bancoagrícola. ¿Me confirma que hablo con ' || cu.full_name || '?'
                       else 'Buenos días, ' || cu.first_name || '. Le saluda el asistente digital de Bancoagrícola. ¿Hablo con ' || cu.full_name || '?' end,
      'nombre', cu.first_name, 'nombre_completo', cu.full_name, 'monto', fmt_money(v_amt), 'fecha', fmt_date_es(ins.due_date),
      'nueva_fecha', fmt_date_es(v_new), 'pago_inicial', fmt_money(round(v_amt * .2, 2)),
      'monto_cuota_plan', fmt_money(round(v_amt * .8 / 3, 2)), 'monto_parcial', fmt_money(round(v_amt * .5, 2)),
      'saldo', fmt_money(v_amt - round(v_amt * .5, 2)), 'cultivo', coalesce(cu.agro_profile->>'crop', 'su cultivo'),
      'recibo', v_recibo, 'link', 'http://localhost:3000/pagar/' || v_token);

    insert into conversations (customer_id, loan_id, channel, direction, status, playbook_id, playbook_key, current_stage,
                               matched_rules, allowed_offers, tone, risk_before, experiment_id, arm_key, models,
                               prompt_versions, is_synthetic, started_at, created_at)
    values (cu.id, ln.id, sc.channel, 'outbound', 'active', v_pbid, v_pb, 'APERTURA',
            (select jsonb_build_array(jsonb_build_object('key', key, 'name', name, 'priority', priority)) from collection_rules where key = v_rule),
            v_offers, (select tone from collection_rules where key = v_rule), v_risk_b,
            case when sc.channel = 'voice' then (select id from experiments where key = 'EXP-VOZ-02') end,
            case when sc.channel = 'voice' then v_arm end,
            case when sc.channel = 'voice'
                 then jsonb_build_object('voice_realtime', jsonb_build_object('key', v_voice), 'supervisor', jsonb_build_object('key','supervisor.gemini-2.5-flash-lite'))
                 else jsonb_build_object('composer', jsonb_build_object('key','composer.gemini-3.1-flash-lite'), 'supervisor', jsonb_build_object('key','supervisor.gemini-2.5-flash-lite')) end,
            '{"voice.system":1,"supervisor.scorecard":1,"composer.whatsapp":1}', true, v_start, v_start)
    returning id into v_conv;

    insert into conversation_events (conversation_id, customer_id, event_type, stage_key, payload, created_at)
    values (v_conv, cu.id, 'conversation_started', 'APERTURA',
            jsonb_build_object('channel', sc.channel, 'playbook', v_pb, 'rules', jsonb_build_array(v_rule), 'synthetic', true), v_start);

    v_t := v_start; v_seq := 0; v_eseq := 0; v_first_s := null; v_last_s := null; v_intent := null;
    v_agent_audio := 0; v_cust_turns := 0; v_agent_turns := 0; v_cm := null; v_link := null; v_cur_st := 'APERTURA';
    v_nlines := jsonb_array_length(a->'lines');

    for v_idx in 0 .. v_nlines - 1 loop
      ln_j := a->'lines'->v_idx;
      v_text := render_template(ln_j->>'t', v_vars);
      v_seq := v_seq + 1;

      if ln_j->>'r' = 'agent' then
        v_agent_turns := v_agent_turns + 1;
        v_lat := case when sc.channel = 'voice'
                      then case when drand(v_conv::text || v_seq || 'sp') < .05 then dint(v_conv::text || v_seq, 2400, 3400)
                                else dint(v_conv::text || v_seq, 650, 2100) end
                      else dint(v_conv::text || v_seq, 1200, 3800) end;
        v_t := v_t + make_interval(secs => v_lat / 1000.0);
        v_audio := case when sc.channel = 'voice' then length(v_text) * 62 end;
        v_heard := case when sc.channel = 'voice' and ln_j ? 'interrupt_voice' then render_template(ln_j->>'interrupt_voice', v_vars) end;
        if (ln_j->>'s') <> v_cur_st then
          insert into conversation_events (conversation_id, customer_id, event_type, stage_key, payload, created_at)
          values (v_conv, cu.id, 'stage_changed', ln_j->>'s', jsonb_build_object('from', v_cur_st, 'to', ln_j->>'s', 'synthetic', true), v_t);
          v_cur_st := ln_j->>'s';
        end if;
        if ln_j ? 'offer_presented' then
          insert into conversation_events (conversation_id, customer_id, event_type, stage_key, payload, created_at)
          values (v_conv, cu.id, 'offer_validated', v_cur_st, jsonb_build_object('offer_code', a->>'offer'), v_t);
        end if;
        insert into messages (conversation_id, seq, role, content, stage_key, input_modality, latency_ms, audio_ms, played_ms,
                              interrupted, heard_text, model_profile_key, prompt_version_key, created_at)
        values (v_conv, v_seq, 'agent', v_text, v_cur_st, case when sc.channel = 'voice' then 'audio' else 'text' end, v_lat,
                v_audio, case when v_heard is not null then (v_audio * length(v_heard) / greatest(length(v_text), 1)) else v_audio end,
                v_heard is not null, v_heard,
                case when sc.channel = 'voice' then v_voice else 'composer.gemini-3.1-flash-lite' end,
                case when sc.channel = 'voice' then 'voice.system@1' else 'composer.whatsapp@1' end, v_t)
        returning id into v_msg;
        if v_heard is not null then
          insert into conversation_events (conversation_id, customer_id, event_type, severity, stage_key, payload, created_at)
          values (v_conv, cu.id, 'interruption_real', case when ln_j ? 'offer_presented' then 'warning' else 'info' end, v_cur_st,
                  jsonb_build_object('message_id', v_msg, 'heard_text', v_heard,
                                     'played_pct', round(100.0 * length(v_heard) / greatest(length(v_text), 1)),
                                     'terms_invalidated', case when ln_j ? 'offer_presented' then jsonb_build_array(a->>'offer') else '[]'::jsonb end),
                  v_t + make_interval(secs => (v_audio * length(v_heard) / greatest(length(v_text), 1)) / 1000.0));
          update conversations set interruption_count = interruption_count + 1 where id = v_conv;
        end if;
        v_t := v_t + make_interval(secs => coalesce(case when v_heard is not null then v_audio * length(v_heard) / greatest(length(v_text), 1) else v_audio end, 0) / 1000.0);
        v_agent_audio := v_agent_audio + coalesce(v_audio, 0);

        -- compromiso registrado en este punto
        if (ln_j ? 'commit') and a->>'offer' is not null and v_cm is null then
          select * into v_offer from offers where code = a->>'offer';
          v_commit_amt := case v_offer.offer_type when 'INSTALLMENT_PLAN' then round(v_amt * .2, 2)
                                                  when 'PARTIAL_PAYMENT' then round(v_amt * .5, 2) else v_amt end;
          v_commit_date := case v_offer.offer_type when 'INSTALLMENT_PLAN' then v_new when 'PARTIAL_PAYMENT' then v_date
                                                   when 'DATE_EXTENSION' then v_new else ins.due_date end;
          v_status := case
            when coalesce(a->>'approval', 'false')::boolean then case when sc.kept then 'approved' else 'cancelled' end
            when sc.kept then 'kept'
            when v_commit_date < v_today then 'broken'
            else 'pending' end;
          insert into commitments (conversation_id, customer_id, loan_id, installment_id, offer_code, commitment_type, amount,
                                   committed_date, original_due_date, params, terms_text, status, requires_approval,
                                   customer_confirmed, policy_validated, receipt_code, is_synthetic, created_at, resolved_at)
          values (v_conv, cu.id, ln.id, ins.id, v_offer.code, v_offer.offer_type, v_commit_amt, v_commit_date, ins.due_date,
                  jsonb_build_object('amount', v_commit_amt, 'date', v_commit_date), v_offer.terms_template, v_status,
                  v_offer.requires_approval, true, true, v_recibo, true, v_t,
                  case when v_status in ('kept','broken','approved','cancelled') then v_t + interval '2 days' end)
          returning id into v_cm;
          update conversations set commitment_id = v_cm where id = v_conv;
          insert into conversation_events (conversation_id, customer_id, event_type, stage_key, payload, created_at)
          values (v_conv, cu.id, 'commitment_registered', v_cur_st,
                  jsonb_build_object('commitment_id', v_cm, 'receipt_code', v_recibo, 'offer_code', v_offer.code, 'status', v_status), v_t);

          if v_offer.requires_approval then
            insert into escalations (conversation_id, customer_id, reason, trigger, priority, status, assigned_to, sla_due_at,
                                     is_synthetic, created_at, resolved_at, notes)
            values (v_conv, cu.id, 'Aprobación requerida: ' || v_offer.name, 'OFFER_REQUIRES_APPROVAL', 'medium', 'resolved',
                    'asesor.agro@demo', v_t + interval '24 hours', true, v_t, v_t + interval '20 hours',
                    case when sc.kept then 'Aprobado: flujo de caja ligado a cosecha.' else 'No aprobado: capacidad insuficiente.' end);
            if sc.kept then
              update installments set status = 'rescheduled', amount_paid = 0, paid_at = null, days_late = 0, late_fee = 0 where id = ins.id;
              delete from payments where installment_id = ins.id;
            end if;
          end if;

          if coalesce(a->>'link', 'false')::boolean then
            insert into payment_links (token, customer_id, loan_id, conversation_id, commitment_id, amount, concept, url, status,
                                       opened_at, paid_at, expires_at, is_synthetic, created_at)
            values (v_token, cu.id, ln.id, v_conv, v_cm, v_commit_amt, 'Compromiso ' || v_recibo,
                    'http://localhost:3000/pagar/' || v_token,
                    case when sc.kept then 'paid' when v_t + interval '48 hours' < now() then 'expired' else 'active' end,
                    case when drand(v_token) < .85 then v_t + interval '5 minutes' end,
                    case when sc.kept then (select max(paid_at) from payments where installment_id = ins.id) end,
                    v_t + interval '48 hours', true, v_t)
            returning id into v_link;
            if sc.kept then
              update payments set channel = 'link_pago', payment_link_id = v_link where installment_id = ins.id;
            end if;
            insert into conversation_events (conversation_id, customer_id, event_type, stage_key, payload, created_at)
            values (v_conv, cu.id, 'payment_link_created', v_cur_st, jsonb_build_object('payment_link_id', v_link, 'amount', v_commit_amt), v_t);
          end if;
        end if;

      else
        v_cust_turns := v_cust_turns + 1;
        v_t := v_t + case when sc.channel = 'voice'
                          then make_interval(secs => (dint(v_conv::text || v_seq || 'p', 400, 1500) + length(v_text) * 70) / 1000.0)
                          else make_interval(secs => dint(v_conv::text || v_seq || 'w', 15, 400)) end;
        insert into messages (conversation_id, seq, role, content, stage_key, input_modality, created_at)
        values (v_conv, v_seq, 'customer', v_text, v_cur_st, case when sc.channel = 'voice' then 'audio' else 'text' end, v_t)
        returning id into v_msg;

        if ln_j ? 'sc' then
          v_eseq := v_eseq + 1;
          v_first_s := coalesce(v_first_s, ln_j->'sc'->>'sentiment');
          v_last_s  := coalesce(ln_j->'sc'->>'sentiment', v_last_s);
          v_intent  := coalesce(ln_j->'sc'->>'intent', v_intent);
          select l2->>'s' into v_next_st from jsonb_array_elements(a->'lines') with ordinality x(l2, o)
           where o > v_idx + 1 and l2->>'r' = 'agent' order by o limit 1;
          v_next_st := coalesce(v_next_st, v_cur_st);
          insert into turn_evaluations (conversation_id, message_id, seq, stage_key, scorecard, intent, sentiment, sentiment_score,
                                        resistance, engagement, commitment_signal, confidence, decision, from_stage, to_stage,
                                        rule_id, rule_label, pace, evaluator_model_key, latency_ms, created_at)
          values (v_conv, v_msg, v_eseq, v_cur_st, ln_j->'sc', ln_j->'sc'->>'intent', ln_j->'sc'->>'sentiment',
                  jnum(ln_j->'sc'->'sentiment_score'), jnum(ln_j->'sc'->'resistance'), jnum(ln_j->'sc'->'engagement'),
                  ln_j->'sc'->>'commitment_signal', jnum(ln_j->'sc'->'confidence'),
                  case when v_next_st = v_cur_st then 'stay'
                       when v_next_st in ('ESCALADO') then 'escalate'
                       when v_next_st in ('CIERRE','NEGATIVA_RESPETADA','CIERRE_TERCERO','REAGENDADO') then 'end'
                       else 'advance' end,
                  v_cur_st, v_next_st, 'SEED', 'Transición de ejemplo (seed)',
                  case when ln_j->'sc'->>'sentiment' in ('FRUSTRATED','ANGRY') or coalesce(jnum(ln_j->'sc'->'resistance'), 0) >= .6 then 'slow'
                       when coalesce(jnum(ln_j->'sc'->'engagement'), 0) >= .7 and ln_j->'sc'->>'commitment_signal' in ('strong','explicit') then 'fast'
                       else 'normal' end,
                  'supervisor.gemini-2.5-flash-lite', dint(v_conv::text || v_seq || 'ev', 280, 900),
                  v_t + make_interval(secs => dint(v_conv::text || v_seq || 'ev', 280, 900) / 1000.0));
        end if;
      end if;
    end loop;

    if jsonb_array_length(a->'lines') = 0 and sc.channel = 'voice' then
      v_t := v_start + interval '32 seconds';
      insert into conversation_events (conversation_id, customer_id, event_type, severity, payload, created_at)
      values (v_conv, cu.id, 'no_answer', 'info', '{"rings":6}', v_t);
    end if;

    -- Efectos posteriores
    if a ? 'signal' then
      insert into customer_signals (customer_id, signal_type, severity, detail, source, detected_at, expires_at, is_active)
      values (cu.id, a->>'signal', 'high', 'Expresó dificultad económica en conversación del ' || to_char(v_date, 'DD/MM'),
              'conversacion', v_t, v_t + interval '60 days', v_t + interval '60 days' > now());
    end if;
    if coalesce(a->>'opt_out', 'false')::boolean then
      update customers set opted_out_at = v_t, opt_out_reason = 'Solicitado por el cliente durante la conversación' where id = cu.id;
      insert into conversation_events (conversation_id, customer_id, event_type, severity, payload, created_at)
      values (v_conv, cu.id, 'opt_out_registered', 'warning', '{}', v_t);
    end if;
    if a ? 'escalate' then
      insert into escalations (conversation_id, customer_id, reason, trigger, priority, status, assigned_to, sla_due_at,
                               is_synthetic, created_at, resolved_at, notes)
      values (v_conv, cu.id, a->>'escalate', case when a->>'escalate' like 'Cliente pide%' then 'G-HUMANO' else 'G-FRUSTRACION' end,
              'high', case when v_t > now() - interval '6 days' or drand(v_conv::text || 'esc') < .15 then 'open' else 'resolved' end,
              'asesor.cobros@demo', v_t + interval '24 hours', true, v_t,
              case when v_t > now() - interval '6 days' or drand(v_conv::text || 'esc') < .15 then null else v_t + interval '26 hours' end,
              'Contactado por asesor.');
      update conversations set escalated = true where id = v_conv;
      insert into conversation_events (conversation_id, customer_id, event_type, payload, created_at)
      values (v_conv, cu.id, 'escalation_created', jsonb_build_object('reason', a->>'escalate'), v_t);
    end if;
    if a ? 'handoff' then
      insert into handoffs (customer_id, from_conversation_id, from_channel, to_channel, action, payload, context_summary,
                            status, scheduled_for, claimed_at, completed_at, is_synthetic, created_at)
      values (cu.id, v_conv, sc.channel, 'whatsapp', a->>'handoff',
              jsonb_build_object('payment_url', case when v_link is not null then 'http://localhost:3000/pagar/' || v_token end,
                                 'receipt_code', case when v_cm is not null then v_recibo end),
              format('Conversación por %s con %s. %s', sc.channel, cu.first_name, coalesce('Compromiso ' || v_recibo, 'Sin compromiso.')),
              'completed', v_t, v_t + interval '3 seconds', v_t + interval '8 seconds', true, v_t);
      insert into conversation_events (conversation_id, customer_id, event_type, payload, created_at)
      values (v_conv, cu.id, 'handoff_created', jsonb_build_object('to_channel', 'whatsapp', 'action', a->>'handoff'), v_t);
    end if;

    -- Uso de modelos (costo real con precios de ai_model_profiles)
    if sc.channel = 'voice' and v_nlines > 0 then
      perform record_model_usage(v_conv, v_voice, jsonb_build_object(
        'audio_in_seconds', extract(epoch from v_t - v_start), 'audio_out_seconds', v_agent_audio / 1000.0,
        'latency_ms', dint(v_conv::text || 'vl', 700, 1500)));
      perform record_model_usage(v_conv, 'supervisor.gemini-2.5-flash-lite', jsonb_build_object(
        'text_in_tokens', v_cust_turns * 1400, 'text_out_tokens', v_cust_turns * 180, 'latency_ms', dint(v_conv::text || 'sl', 300, 800)));
    elsif v_nlines > 0 then
      perform record_model_usage(v_conv, 'composer.gemini-3.1-flash-lite', jsonb_build_object(
        'text_in_tokens', v_agent_turns * 2600, 'text_out_tokens', v_agent_turns * 90, 'latency_ms', dint(v_conv::text || 'cl', 900, 2400)));
      perform record_model_usage(v_conv, 'supervisor.gemini-2.5-flash-lite', jsonb_build_object(
        'text_in_tokens', v_cust_turns * 1400, 'text_out_tokens', v_cust_turns * 180, 'latency_ms', dint(v_conv::text || 'sl', 300, 800)));
    end if;
    update model_usage set created_at = v_t where conversation_id = v_conv;

    update conversations set
      status          = case when a->>'outcome' = 'NO_ANSWER' then 'no_answer' else 'completed' end,
      outcome         = a->>'outcome',
      current_stage   = v_cur_st,
      turn_count      = v_cust_turns,
      sentiment_start = v_first_s,
      sentiment_end   = v_last_s,
      final_intent    = v_intent,
      ended_at        = v_t + interval '2 seconds',
      last_message_at = v_t,
      duration_ms     = (extract(epoch from v_t - v_start) * 1000)::int + 2000,
      avg_latency_ms  = (select avg(latency_ms)::int from messages where conversation_id = v_conv and role = 'agent'),
      p95_latency_ms  = (select (percentile_cont(0.95) within group (order by latency_ms))::int from messages where conversation_id = v_conv and role = 'agent'),
      risk_after      = v_risk_b - case when v_cm is not null then dint(v_conv::text || 'ra', 8, 18)
                                        when a ? 'escalate' then dint(v_conv::text || 'ra', 0, 4) else dint(v_conv::text || 'ra', -3, 3) end,
      summary         = case a->>'outcome'
                          when 'PAYMENT_COMMITMENT' then 'Cliente confirmó pago completo en fecha. Se envió link por WhatsApp.'
                          when 'PAYMENT_PLAN_AGREED' then 'Dificultad temporal por atraso de salario. Aceptó pago inicial y 3 pagos quincenales.'
                          when 'PARTIAL_PAYMENT_AGREED' then 'Pagará 50% ahora y el saldo en 10 días. Interrumpió durante las condiciones; se repitieron antes de confirmar.'
                          when 'PENDING_APPROVAL' then 'Productor sin ingreso hasta la cosecha. Solicitó diferir la cuota; pasa a aprobación.'
                          when 'FOLLOW_UP_REQUIRED' then 'Respuesta evasiva. Aceptó recibir opciones por WhatsApp.'
                          when 'HUMAN_ESCALATION' then 'Cliente molesto o pidió asesor. Se escaló sin insistir.'
                          when 'EXPLICIT_REFUSAL' then 'Rechazó dos veces. Se respetó la decisión sin ofrecer más.'
                          when 'WRONG_PERSON' then 'Contestó un tercero. No se reveló información.'
                          when 'PAID_DURING_CONTACT' then 'Pagó con el link durante la conversación de WhatsApp.'
                          when 'DO_NOT_CONTACT' then 'Pidió no ser contactado. Opt-out registrado.'
                          when 'NO_ANSWER' then 'No contestó.'
                          when 'ABANDONED' then 'Mensaje entregado sin respuesta del cliente.'
                          when 'DATE_EXTENSION_AGREED' then 'Pidió mover la fecha por atraso de ingreso. Nueva fecha dentro de política.' end
    where id = v_conv;

    insert into conversation_events (conversation_id, customer_id, event_type, payload, created_at)
    values (v_conv, cu.id, 'conversation_ended', jsonb_build_object('outcome', a->>'outcome', 'synthetic', true), v_t + interval '2 seconds');

    insert into interventions (customer_id, loan_id, status, priority, risk_score, risk_band, matched_rules, offers, playbook_key,
                               channel_sequence, recommended_channel, reason, scheduled_for, dispatched_at, completed_at,
                               conversation_id, is_synthetic, created_at)
    values (cu.id, ln.id, 'completed', v_risk_b, v_risk_b,
            risk_band_for(v_risk_b),
            (select matched_rules from conversations where id = v_conv), v_offers, v_pb, array[sc.channel], sc.channel,
            'Reglas: ' || v_rule, v_start - interval '1 hour', v_start, v_t, v_conv, true, v_start - interval '1 hour');
    update conversations set intervention_id = (select id from interventions where conversation_id = v_conv) where id = v_conv;

    v_n := v_n + 1;
  end loop;
  return v_n;
end $seed$;

-- ─── RESET COMPLETO DE LA DEMO ─────────────────────────────────────────────
create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $seed$
declare
  v_cfg   jsonb;
  v_pers  int;
  v_gen   int;
  v_hist  int;
  v_det   jsonb;
  cu      record;
  v_score int;
begin
  set local statement_timeout = 0;

  truncate detection_runs, model_usage, escalations, handoffs, payment_links, commitments, conversation_events,
           turn_evaluations, messages, conversations, interventions, risk_assessments, customer_signals,
           payments, installments, loans, customers restart identity cascade;

  if p_reset_config or not exists (select 1 from agent_policies where is_active) then
    v_cfg := seed_config();
  end if;

  drop table if exists _seed_contacts;
  create temp table _seed_contacts (
    customer_code text, due_date date, profile text, archetype text, channel text,
    kept boolean, days_before int, days_ago int);

  v_pers := seed_personas();
  v_gen  := seed_customers(p_generated_customers);
  v_hist := seed_history();

  -- Riesgo actual + 2 puntos históricos para la gráfica de evolución
  for cu in select id, risk_profile_seed from customers loop
    v_score := (compute_risk(cu.id, true, 'seed')->>'score')::int;
    insert into risk_assessments (customer_id, loan_id, score, band, probability_default, factors, trigger, computed_at)
    select cu.id, ra.loan_id, s.sc,
           risk_band_for(s.sc),
           round(1 / (1 + exp(-(s.sc - 65) / 12.0)), 4), '[]', 'seed_backfill', now() - make_interval(days => s.d)
      from (select loan_id from risk_assessments where customer_id = cu.id order by computed_at desc limit 1) ra,
           lateral (values
             (60, greatest(0, least(100, v_score - case when cu.risk_profile_seed in ('ALTO','CRITICO','PREVENTIVO')
                                                        then dint(cu.id::text || '60', 6, 16) else dint(cu.id::text || '60', -4, 4) end))),
             (30, greatest(0, least(100, v_score - case when cu.risk_profile_seed in ('ALTO','CRITICO','PREVENTIVO')
                                                        then dint(cu.id::text || '30', 2, 8) else dint(cu.id::text || '30', -3, 3) end)))
           ) s(d, sc);
  end loop;

  v_det := run_detection();
  drop table if exists _seed_contacts;

  return jsonb_build_object(
    'ok', true,
    'config', v_cfg,
    'personas', v_pers,
    'generated_customers', v_gen,
    'historical_conversations', v_hist,
    'detection', v_det,
    'totals', jsonb_build_object(
      'customers', (select count(*) from customers), 'loans', (select count(*) from loans),
      'installments', (select count(*) from installments), 'payments', (select count(*) from payments),
      'signals', (select count(*) from customer_signals), 'conversations', (select count(*) from conversations),
      'messages', (select count(*) from messages), 'turn_evaluations', (select count(*) from turn_evaluations),
      'commitments', (select count(*) from commitments), 'escalations', (select count(*) from escalations),
      'payment_links', (select count(*) from payment_links), 'events', (select count(*) from conversation_events)),
    'next_step', 'Habilita tu número: select set_demo_contact(''DEMO-001'', ''+503XXXXXXXX'');');
end $seed$;

revoke execute on function reset_demo(boolean, int) from public, anon;
grant execute on function reset_demo(boolean, int) to authenticated, service_role;
