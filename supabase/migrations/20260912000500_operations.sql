-- ═══════════════════════════════════════════════════════════════════════════
-- 0500 · Operación: detección, intervenciones, conversaciones, control, resultados
-- Estas tablas son la FUENTE COMPARTIDA entre voz, WhatsApp y web.
-- ═══════════════════════════════════════════════════════════════════════════

create table detection_runs (
  id                   uuid primary key default gen_random_uuid(),
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  customers_evaluated  int not null default 0,
  scheduled            int not null default 0,
  blocked              int not null default 0,
  control_group        int not null default 0,
  no_action            int not null default 0,
  summary              jsonb not null default '{}'
);

-- La DECISIÓN preventiva. Existe ANTES del contacto.
create table interventions (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null references customers(id) on delete cascade,
  loan_id              uuid references loans(id) on delete cascade,
  risk_assessment_id   uuid references risk_assessments(id) on delete set null,
  detection_run_id     uuid references detection_runs(id) on delete set null,
  status               text not null default 'scheduled' check (status in
                       ('scheduled','dispatched','completed','blocked','control_group','skipped','expired')),
  priority             int not null default 50,
  risk_score           int,
  risk_band            text,
  matched_rules        jsonb not null default '[]',
  block_reasons        jsonb not null default '[]',
  offers               jsonb not null default '[]',
  playbook_key         text,
  channel_sequence     text[] not null default '{}',
  recommended_channel  text,
  reason               text,
  scheduled_for        timestamptz not null default now(),
  dispatched_at        timestamptz,
  completed_at         timestamptz,
  conversation_id      uuid,
  is_synthetic         boolean not null default false,
  created_at           timestamptz not null default now()
);
create index on interventions (status, scheduled_for);
create index on interventions (customer_id, created_at desc);

create table conversations (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null references customers(id) on delete cascade,
  loan_id                 uuid references loans(id) on delete set null,
  intervention_id         uuid references interventions(id) on delete set null,
  parent_conversation_id  uuid references conversations(id) on delete set null,  -- llamada → WhatsApp
  channel                 text not null check (channel in ('voice','whatsapp','sms','email','simulator')),
  direction               text not null default 'outbound' check (direction in ('outbound','inbound')),
  status                  text not null default 'active' check (status in ('active','completed','no_answer','failed')),
  external_id             text,         -- call id / message SID
  -- control de la conversación
  playbook_id             uuid references playbooks(id) on delete set null,
  playbook_key            text,
  current_stage           text,
  stage_turn_count        int not null default 0,
  turn_count              int not null default 0,
  matched_rules           jsonb not null default '[]',   -- SNAPSHOT al iniciar (auditoría)
  allowed_offers          jsonb not null default '[]',   -- SNAPSHOT al iniciar
  constraints             jsonb not null default '{}',
  tone                    text,
  context_snapshot        jsonb,
  terms_presented         text[] not null default '{}',  -- ofertas cuyas condiciones se dijeron
  terms_interrupted       text[] not null default '{}',  -- se interrumpieron → hay que repetirlas
  refusal_count           int not null default 0,
  negative_streak         int not null default 0,
  low_confidence_streak   int not null default 0,
  -- interrupciones
  interruption_count      int not null default 0,
  false_barge_in_count    int not null default 0,
  backchannel_count       int not null default 0,
  silence_reprompt_count  int not null default 0,
  -- resultado
  sentiment_start         text,
  sentiment_end           text,
  final_intent            text,
  outcome                 text,
  outcome_reason          text,
  summary                 text,
  commitment_id           uuid,
  escalated               boolean not null default false,
  risk_before             int,
  risk_after              int,
  -- modelos / experimento / costo
  experiment_id           uuid references experiments(id) on delete set null,
  arm_key                 text,
  models                  jsonb not null default '{}',   -- {voice_realtime, supervisor, composer}
  prompt_versions         jsonb not null default '{}',
  cost_usd                numeric(10,5) not null default 0,
  avg_latency_ms          int,
  p95_latency_ms          int,
  recording_url           text,
  is_synthetic            boolean not null default false,
  started_at              timestamptz not null default now(),
  last_message_at         timestamptz,
  ended_at                timestamptz,
  duration_ms             int,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create index on conversations (customer_id, started_at desc);
create index on conversations (status) where status = 'active';
create index on conversations (started_at desc);
create trigger trg_conversations_updated before update on conversations for each row execute function touch_updated_at();

alter table interventions add constraint interventions_conversation_fk
  foreign key (conversation_id) references conversations(id) on delete set null;

create table messages (
  id                  uuid primary key default gen_random_uuid(),
  conversation_id     uuid not null references conversations(id) on delete cascade,
  seq                 int not null,
  role                text not null check (role in ('agent','customer','system','tool')),
  content             text not null,
  stage_key           text,
  input_modality      text not null default 'text' check (input_modality in ('text','audio','voice_note','image')),
  media_url           text,
  -- latencia
  latency_ms          int,        -- agente: fin del turno del cliente → primer audio/texto
  ttfb_ms             int,
  -- interrupciones (voz)
  audio_ms            int,        -- duración total del audio generado
  played_ms           int,        -- cuánto alcanzó a sonar
  interrupted         boolean not null default false,
  heard_text          text,       -- lo que el cliente REALMENTE escuchó
  is_backchannel      boolean not null default false,
  -- modelo
  model_profile_key   text,
  prompt_version_key  text,
  tokens_in           int,
  tokens_out          int,
  meta                jsonb not null default '{}',
  created_at          timestamptz not null default now(),
  unique (conversation_id, seq)
);
create index on messages (conversation_id, seq);

-- Scorecard + decisión del controlador por turno
create table turn_evaluations (
  id                   uuid primary key default gen_random_uuid(),
  conversation_id      uuid not null references conversations(id) on delete cascade,
  message_id           uuid references messages(id) on delete set null,
  seq                  int not null,
  stage_key            text,
  scorecard            jsonb not null,
  intent               text,
  sentiment            text,
  sentiment_score      numeric(4,3),
  resistance           numeric(4,3),
  engagement           numeric(4,3),
  commitment_signal    text,
  confidence           numeric(4,3),
  decision             text not null check (decision in ('stay','advance','jump','escalate','end','ignored')),
  from_stage           text,
  to_stage             text,
  rule_id              text,
  rule_label           text,
  pace                 text check (pace in ('slow','normal','fast')),
  control_message      text,
  evaluator_model_key  text,
  latency_ms           int,
  created_at           timestamptz not null default now()
);
create index on turn_evaluations (conversation_id, seq);

create table conversation_events (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid references conversations(id) on delete cascade,
  customer_id      uuid references customers(id) on delete cascade,
  event_type       text not null,
  severity         text not null default 'info' check (severity in ('info','warning','error')),
  stage_key        text,
  payload          jsonb not null default '{}',
  latency_ms       int,
  created_at       timestamptz not null default now()
);
create index on conversation_events (conversation_id, created_at);
create index on conversation_events (event_type, created_at desc);

create table commitments (
  id                   uuid primary key default gen_random_uuid(),
  conversation_id      uuid references conversations(id) on delete set null,
  customer_id          uuid not null references customers(id) on delete cascade,
  loan_id              uuid references loans(id) on delete cascade,
  installment_id       uuid references installments(id) on delete set null,
  offer_code           text not null,
  commitment_type      text not null,
  amount               numeric(12,2),
  committed_date       date,
  original_due_date    date,
  params               jsonb not null default '{}',
  terms_text           text,
  status               text not null default 'pending' check (status in
                       ('pending','pending_approval','approved','kept','broken','cancelled')),
  requires_approval    boolean not null default false,
  customer_confirmed   boolean not null default false,
  policy_validated     boolean not null default false,
  receipt_code         text unique not null,
  is_synthetic         boolean not null default false,
  created_at           timestamptz not null default now(),
  resolved_at          timestamptz
);
create index on commitments (customer_id, status);

alter table conversations add constraint conversations_commitment_fk
  foreign key (commitment_id) references commitments(id) on delete set null;

create table payment_links (
  id               uuid primary key default gen_random_uuid(),
  token            text unique not null,
  customer_id      uuid not null references customers(id) on delete cascade,
  loan_id          uuid references loans(id) on delete cascade,
  conversation_id  uuid references conversations(id) on delete set null,
  commitment_id    uuid references commitments(id) on delete set null,
  amount           numeric(12,2) not null,
  concept          text not null,
  url              text not null,
  status           text not null default 'active' check (status in ('active','paid','expired','cancelled')),
  opened_at        timestamptz,
  paid_at          timestamptz,
  expires_at       timestamptz not null,
  is_synthetic     boolean not null default false,
  created_at       timestamptz not null default now()
);

alter table payments add constraint payments_link_fk
  foreign key (payment_link_id) references payment_links(id) on delete set null;

-- Siguiente paso en OTRO canal (ej. llamada → WhatsApp con link de pago)
create table handoffs (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  from_conversation_id  uuid references conversations(id) on delete set null,
  to_conversation_id    uuid references conversations(id) on delete set null,
  from_channel          text,
  to_channel            text not null,
  action                text not null check (action in
                        ('SEND_PAYMENT_LINK','SEND_COMMITMENT_SUMMARY','SEND_OFFER_DETAILS','FOLLOW_UP_MESSAGE','CALLBACK')),
  payload               jsonb not null default '{}',
  context_summary       text,
  status                text not null default 'pending' check (status in ('pending','processing','completed','failed','cancelled')),
  scheduled_for         timestamptz not null default now(),
  claimed_at            timestamptz,
  completed_at          timestamptz,
  is_synthetic          boolean not null default false,
  created_at            timestamptz not null default now()
);
create index on handoffs (to_channel, status, scheduled_for);

create table escalations (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid references conversations(id) on delete set null,
  customer_id      uuid not null references customers(id) on delete cascade,
  reason           text not null,
  trigger          text,
  priority         text not null default 'high' check (priority in ('low','medium','high','urgent')),
  status           text not null default 'open' check (status in ('open','in_progress','resolved')),
  assigned_to      text,
  notes            text,
  sla_due_at       timestamptz,
  is_synthetic     boolean not null default false,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz
);
create index on escalations (status, priority);

create table model_usage (
  id                 uuid primary key default gen_random_uuid(),
  conversation_id    uuid references conversations(id) on delete cascade,
  eval_run_id        uuid references eval_runs(id) on delete cascade,
  model_profile_key  text not null,
  role               text,
  provider           text,
  model_id           text,
  audio_in_seconds   numeric(10,2) not null default 0,
  audio_out_seconds  numeric(10,2) not null default 0,
  audio_in_tokens    int not null default 0,
  audio_out_tokens   int not null default 0,
  text_in_tokens     int not null default 0,
  text_out_tokens    int not null default 0,
  cached_tokens      int not null default 0,
  latency_ms         int,
  ttfb_ms            int,
  cost_usd           numeric(10,6) not null default 0,
  error              text,
  created_at         timestamptz not null default now()
);
create index on model_usage (model_profile_key, created_at desc);
