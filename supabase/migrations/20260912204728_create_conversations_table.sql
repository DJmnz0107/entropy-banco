create table if not exists public.conversations (
  phone_number text primary key,
  history jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
