-- ═══════════════════════════════════════════════════════════════════════════
-- 0300 · Configuración del negocio (lo que el equipo de ventas edita en la web)
--
--   offers              → QUÉ se puede ofrecer
--   collection_rules    → CUÁNDO aplica cada oferta (condiciones sobre datos)
--   playbooks + stages  → CÓMO se conduce la conversación (etapas + criterios)
--   evaluation_criteria → QUÉ se evalúa en cada turno
--   agent_policies      → límites globales, interrupciones, ritmo, riesgo
-- ═══════════════════════════════════════════════════════════════════════════

-- Catálogo de "hechos" que la web muestra en el constructor de reglas
create table rule_fact_definitions (
  key         text primary key,
  label       text not null,
  description text,
  data_type   text not null check (data_type in ('number','text','boolean','list','enum')),
  operators   text[] not null,
  options     jsonb,
  scope       text not null default 'customer' check (scope in ('customer','turn')),
  sort_order  int not null default 100
);

create table offers (
  id                      uuid primary key default gen_random_uuid(),
  code                    text unique not null,
  name                    text not null,
  offer_type              text not null check (offer_type in
                          ('FULL_PAYMENT','PARTIAL_PAYMENT','DATE_EXTENSION','INSTALLMENT_PLAN',
                           'FEE_WAIVER','REMINDER','CALLBACK','HUMAN_ADVISOR')),
  description             text,
  pitch_script            text,     -- guía de cómo presentarla (script de la empresa)
  terms_template          text,     -- condiciones exactas; el agente debe decirlas textual
  cta_label               text,     -- texto de botón en WhatsApp
  params                  jsonb not null default '{}',
  eligibility             jsonb not null default '{}',  -- condición extra sobre hechos del cliente
  requires_approval       boolean not null default false,
  disclosure_required     boolean not null default true,
  generates_payment_link  boolean not null default false,
  is_active               boolean not null default true,
  created_by              text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create trigger trg_offers_updated before update on offers for each row execute function touch_updated_at();

create table playbooks (
  id             uuid primary key default gen_random_uuid(),
  key            text unique not null,
  name           text not null,
  description    text,
  channel_scope  text[] not null default '{voice,whatsapp,sms,email}',
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger trg_playbooks_updated before update on playbooks for each row execute function touch_updated_at();

create table evaluation_criteria (
  key         text primary key,
  label       text not null,
  description text not null,        -- esto va literal al prompt del supervisor
  value_type  text not null check (value_type in ('boolean','score','enum','text','number')),
  options     jsonb,
  sort_order  int not null default 100
);

create table playbook_stages (
  id                  uuid primary key default gen_random_uuid(),
  playbook_id         uuid not null references playbooks(id) on delete cascade,
  stage_key           text not null,
  position            int not null,
  name                text not null,
  objective           text,
  agent_instructions  text,
  criteria            text[] not null default '{}',   -- keys de evaluation_criteria a evaluar
  exit_rules          jsonb not null default '[]',    -- [{id,label,when:{condición},go_to,instruction}]
  max_turns           int not null default 3,
  on_max_turns_go_to  text,
  allows_offers       boolean not null default false,
  is_terminal         boolean not null default false,
  suggested_outcome   text,
  unique (playbook_id, stage_key)
);

create table collection_rules (
  id                uuid primary key default gen_random_uuid(),
  key               text unique not null,
  name              text not null,
  description       text,
  effect            text not null default 'allow' check (effect in ('allow','block')),
  priority          int not null default 50,          -- mayor = se evalúa primero
  conditions        jsonb not null,                   -- {"all":[{"fact","op","value"}, {"any":[...]}]}
  playbook_key      text,
  channel_sequence  text[] not null default '{whatsapp}',
  tone              text not null default 'calido',
  constraints       jsonb not null default '{}',      -- max_* = gana el menor, min_* = gana el mayor
  max_attempts      int not null default 2,
  is_active         boolean not null default true,
  created_by        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger trg_rules_updated before update on collection_rules for each row execute function touch_updated_at();

create table rule_offers (
  rule_id   uuid not null references collection_rules(id) on delete cascade,
  offer_id  uuid not null references offers(id) on delete cascade,
  position  int not null default 1,
  primary key (rule_id, offer_id)
);

create table outcome_definitions (
  code                  text primary key,
  label                 text not null,
  category              text not null check (category in ('success','partial','neutral','negative','technical')),
  counts_as_contact     boolean not null default true,
  counts_as_commitment  boolean not null default false,
  description           text,
  sort_order            int not null default 100
);

create table agent_policies (
  id                           uuid primary key default gen_random_uuid(),
  version                      text not null,
  name                         text not null,
  is_active                    boolean not null default false,
  assistant_name               text not null,
  disclosure_text              text not null,
  default_playbook_key         text not null,
  default_models               jsonb not null default '{}',  -- {voice_realtime, supervisor, composer, ...}
  max_offers_presented         int not null default 3,
  max_turns_per_conversation   int not null default 16,
  max_contacts_per_week        int not null default 2,
  cooldown_hours               int not null default 48,
  quiet_hours                  jsonb not null default '{"start":"20:00","end":"08:00"}',
  forbidden_weekdays           int[] not null default '{7}',   -- ISO: 7 = domingo
  live_contact_allowlist_only  boolean not null default true,
  payment_link_base_url        text not null,
  payment_link_ttl_hours       int not null default 48,
  risk_weights                 jsonb not null,
  risk_bands                   jsonb not null,
  global_transitions           jsonb not null default '[]',
  pace_instructions            jsonb not null default '{}',
  interruption_policy          jsonb not null default '{}',
  prohibited_phrases           text[] not null default '{}',
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now()
);
create unique index agent_policies_one_active on agent_policies (is_active) where is_active;
create trigger trg_policies_updated before update on agent_policies for each row execute function touch_updated_at();
