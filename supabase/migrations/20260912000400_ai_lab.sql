-- ═══════════════════════════════════════════════════════════════════════════
-- 0400 · Laboratorio de modelos: configurar, comparar e iterar
-- Cambiar de modelo = editar una fila. Nada de modelos hardcodeados en código.
-- ═══════════════════════════════════════════════════════════════════════════

create table ai_model_profiles (
  id                   uuid primary key default gen_random_uuid(),
  key                  text unique not null,
  -- voice_realtime = speech-to-speech en un solo modelo (ej. Gemini Live)
  -- stt + composer + tts = pipeline en cascada (ej. Deepgram → Gemini Flash-Lite → Cartesia)
  role                 text not null check (role in
                       ('voice_realtime','stt','tts','supervisor','composer','multimodal','summarizer','customer_simulator','judge')),
  provider             text not null,       -- google, openai, anthropic
  model_id             text not null,       -- ID exacto del API
  display_name         text not null,
  modality             text not null check (modality in ('realtime_audio','speech_to_text','text_to_speech','text','multimodal')),
  params               jsonb not null default '{}',   -- temperature, max_output_tokens, thinking, voice...
  vad_config           jsonb not null default '{}',   -- sensibilidad, padding, silencio, activity_handling
  interruption_config  jsonb not null default '{}',   -- override de agent_policies.interruption_policy
  pricing              jsonb not null default '{}',   -- audio_in_per_min, audio_out_per_min, *_per_1m
  capabilities         jsonb not null default '{}',
  pricing_source_url   text,
  pricing_verified_at  date,               -- null = precio NO verificado
  status               text not null default 'active' check (status in ('active','experimental','unverified','retired')),
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger trg_models_updated before update on ai_model_profiles for each row execute function touch_updated_at();

create table prompt_versions (
  id             uuid primary key default gen_random_uuid(),
  key            text not null,        -- voice.system, supervisor.scorecard, composer.whatsapp...
  version        int not null,
  role           text not null,
  title          text not null,
  content        text not null,
  output_schema  jsonb,
  variables      text[] not null default '{}',
  is_active      boolean not null default false,
  notes          text,
  created_by     text,
  created_at     timestamptz not null default now(),
  unique (key, version)
);
create unique index prompt_versions_one_active on prompt_versions (key) where is_active;

create table experiments (
  id                 uuid primary key default gen_random_uuid(),
  key                text unique not null,
  name               text not null,
  hypothesis         text,
  status             text not null default 'draft' check (status in ('draft','running','paused','finished')),
  channel            text,
  primary_metric     text,
  secondary_metrics  text[] not null default '{}',
  conclusion         text,
  started_at         timestamptz,
  ended_at           timestamptz,
  created_at         timestamptz not null default now()
);

create table experiment_arms (
  id                    uuid primary key default gen_random_uuid(),
  experiment_id         uuid not null references experiments(id) on delete cascade,
  arm_key               text not null,
  name                  text not null,
  traffic_weight        int not null default 50,
  voice_model_key       text references ai_model_profiles(key),
  supervisor_model_key  text references ai_model_profiles(key),
  composer_model_key    text references ai_model_profiles(key),
  prompt_overrides      jsonb not null default '{}',   -- {"voice.system": 2}
  param_overrides       jsonb not null default '{}',
  unique (experiment_id, arm_key)
);

create table eval_scenarios (
  id                 uuid primary key default gen_random_uuid(),
  key                text unique not null,
  name               text not null,
  description        text,
  channel            text not null default 'voice',
  customer_code      text,
  persona_prompt     text not null,     -- instrucciones para el LLM que simula al cliente
  opening_line       text,
  interruption_plan  jsonb not null default '[]',  -- [{at_stage, after_ms, kind, say}]
  expected           jsonb not null default '{}',  -- {outcome, must_reach_stages, must_not}
  tags               text[] not null default '{}',
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);

create table eval_runs (
  id                    uuid primary key default gen_random_uuid(),
  scenario_id           uuid not null references eval_scenarios(id) on delete cascade,
  experiment_id         uuid references experiments(id) on delete set null,
  arm_key               text,
  voice_model_key       text,
  supervisor_model_key  text,
  composer_model_key    text,
  simulator_model_key   text,
  judge_model_key       text,
  prompt_versions       jsonb not null default '{}',
  status                text not null default 'queued' check (status in ('queued','running','passed','failed','error')),
  transcript            jsonb,
  stage_path            text[],
  outcome               text,
  scores                jsonb,   -- {policy_compliance, reached_cta, outcome_correct, empathy, terms_restated_after_interrupt...}
  total_cost_usd        numeric(10,5),
  avg_latency_ms        int,
  p95_latency_ms        int,
  judge_notes           text,
  error                 text,
  is_synthetic          boolean not null default false,
  started_at            timestamptz,
  finished_at           timestamptz,
  created_at            timestamptz not null default now()
);
