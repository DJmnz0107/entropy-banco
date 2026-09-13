-- ═══════════════════════════════════════════════════════════════════════════
-- 1400 · Contactos reales del equipo que sobreviven a reset_demo()
--
-- reset_demo() trunca customers y vuelve a sembrar los personajes con teléfonos
-- no enrutables (+50300…). Esta tabla NO se trunca: guarda qué cliente demo es de
-- qué integrante, con su nombre y contacto real, y reset_demo() lo reaplica al final.
--
-- Los datos (nombres, teléfonos, correos) NO van en git: se cargan una vez con
-- supabase/local/demo-team-contacts.sql (ignorado por git) desde el SQL Editor.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists demo_team_contacts (
  customer_code text primary key,
  first_name    text not null,              -- nombre de pila: saludo casual ("Hola, Josué")
  last_name     text not null,              -- resto del nombre: full_name queda con el nombre completo real
  phone_e164    text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  email         text,                       -- null = conserva el correo demo
  updated_at    timestamptz not null default now()
);

-- Solo servidor: sin políticas para authenticated/anon (datos personales reales)
alter table demo_team_contacts enable row level security;

create or replace function apply_demo_team_contacts()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_count int;
begin
  update customers c
     set first_name      = t.first_name,
         last_name       = t.last_name,
         phone_e164      = t.phone_e164,
         email           = coalesce(t.email, c.email),
         contact_enabled = true,
         opted_out_at    = null,
         opt_out_reason  = null,
         demo_notes      = 'Contacto real de prueba (equipo)',
         updated_at      = now()
    from demo_team_contacts t
   where c.customer_code = t.customer_code;
  get diagnostics v_count = row_count;
  return jsonb_build_object('team_contacts_applied', v_count);
end $$;

revoke execute on function apply_demo_team_contacts() from public, anon, authenticated;

-- reset_demo() reaplica los contactos al final (mismo patrón que la calibración del embudo)
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'reset_demo_pre_team_contacts') then
    alter function reset_demo(boolean, int) rename to reset_demo_pre_team_contacts;
  end if;
end $$;

create or replace function reset_demo(p_reset_config boolean default true, p_generated_customers int default 150)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  v_res := reset_demo_pre_team_contacts(p_reset_config, p_generated_customers);
  return v_res || apply_demo_team_contacts();
end $$;
