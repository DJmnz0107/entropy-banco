-- ═══════════════════════════════════════════════════════════════════════════
-- 0200 · Clientes, créditos, cuotas, pagos, señales, riesgo
-- TODOS LOS DATOS SON FICTICIOS.
-- ═══════════════════════════════════════════════════════════════════════════

create table customers (
  id                        uuid primary key default gen_random_uuid(),
  customer_code             text unique not null,
  first_name                text not null,
  last_name                 text not null,
  full_name                 text generated always as (first_name || ' ' || last_name) stored,
  gender                    text check (gender in ('F','M')),
  birth_date                date,
  document_id               text unique,                  -- DEMO-xxxxxxxx, nunca formato DUI real
  phone_e164                text,                         -- +50300xxxxxx = no enrutable
  email                     text,
  department                text,
  city                      text,
  address_zone              text check (address_zone in ('urbana','rural')),
  segment                   text not null default 'MASIVO',   -- MASIVO, PREFERENTE, AGRO, PYME, PREMIUM
  income_type               text not null,                    -- asalariado, agricultor, comerciante, remesas, independiente
  monthly_income            numeric(12,2),
  occupation                text,
  agro_profile              jsonb,        -- {crop, hectares, harvest_months[], dry_corridor, cooperative}
  preferred_channel         text not null default 'whatsapp' check (preferred_channel in ('voice','whatsapp','sms','email')),
  preferred_contact_window  text check (preferred_contact_window in ('manana','tarde','noche')),
  language                  text not null default 'es-SV',
  consent_voice             boolean not null default true,
  consent_whatsapp          boolean not null default true,
  consent_sms               boolean not null default true,
  consent_email             boolean not null default true,
  opted_out_at              timestamptz,
  opt_out_reason            text,
  -- SEGURIDAD: solo clientes con contact_enabled=true pueden recibir llamadas/mensajes
  -- en vivo. Evita que un job de prueba le escriba a un número real ajeno.
  contact_enabled           boolean not null default false,
  is_control_group          boolean not null default false,  -- nunca se contacta: contrafactual
  is_demo_persona           boolean not null default false,
  risk_profile_seed         text,                            -- perfil con el que se generó (solo seed)
  demo_notes                text,
  customer_since            date,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
create index on customers (phone_e164);
create trigger trg_customers_updated before update on customers for each row execute function touch_updated_at();

create table loans (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null references customers(id) on delete cascade,
  loan_number         text unique not null,
  product_type        text not null check (product_type in ('PERSONAL','AGRICOLA_AVIO','PYME','MICROCREDITO','VIVIENDA')),
  product_name        text not null,
  purpose             text,
  principal           numeric(12,2) not null,
  annual_rate         numeric(6,4) not null,
  term_months         int not null,
  installment_amount  numeric(12,2) not null,
  balance             numeric(12,2) not null,
  disbursed_at        date not null,
  payment_day         int,
  late_fee_amount     numeric(10,2) not null default 10.00,
  status              text not null default 'active' check (status in ('active','paid_off','written_off','restructured')),
  created_at          timestamptz not null default now()
);
create index on loans (customer_id) where status = 'active';

create table installments (
  id              uuid primary key default gen_random_uuid(),
  loan_id         uuid not null references loans(id) on delete cascade,
  number          int not null,
  due_date        date not null,
  amount_due      numeric(12,2) not null,
  principal_part  numeric(12,2),
  interest_part   numeric(12,2),
  amount_paid     numeric(12,2) not null default 0,
  paid_at         date,
  days_late       int not null default 0,
  late_fee        numeric(10,2) not null default 0,
  status          text not null default 'pending'
                  check (status in ('pending','paid','paid_late','partial','overdue','rescheduled','waived')),
  unique (loan_id, number)
);
create index on installments (loan_id, due_date);
create index on installments (due_date) where status in ('pending','partial','overdue');

create table payments (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null references customers(id) on delete cascade,
  loan_id         uuid not null references loans(id) on delete cascade,
  installment_id  uuid references installments(id) on delete set null,
  amount          numeric(12,2) not null,
  paid_at         timestamptz not null,
  channel         text not null,   -- agencia, app, banca_en_linea, corresponsal, link_pago, debito_automatico
  reference       text,
  payment_link_id uuid,            -- FK agregada en 0500
  is_synthetic    boolean not null default true,
  created_at      timestamptz not null default now()
);
create index on payments (customer_id, paid_at desc);

create table signal_definitions (
  code              text primary key,
  label             text not null,
  description       text,
  category          text,          -- ingreso, comportamiento, agro, contacto, legal
  default_severity  text check (default_severity in ('low','medium','high'))
);

create table customer_signals (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers(id) on delete cascade,
  signal_type  text not null references signal_definitions(code),
  severity     text not null check (severity in ('low','medium','high')),
  detail       text,
  value        numeric,
  source       text,               -- core_bancario, app, conversacion, clima, buro
  detected_at  timestamptz not null default now(),
  expires_at   timestamptz,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);
create index on customer_signals (customer_id) where is_active;

create table risk_assessments (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          uuid not null references customers(id) on delete cascade,
  loan_id              uuid references loans(id) on delete cascade,
  score                int not null check (score between 0 and 100),
  band                 text not null,
  probability_default  numeric(5,4),
  factors              jsonb not null default '[]',   -- [{key,label,weight,value,points,detail}]
  facts                jsonb,
  model_version        text not null default 'weighted-v1',
  trigger              text not null default 'detection',
  computed_at          timestamptz not null default now()
);
create index on risk_assessments (customer_id, computed_at desc);
