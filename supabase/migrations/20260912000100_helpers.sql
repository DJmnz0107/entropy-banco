-- ═══════════════════════════════════════════════════════════════════════════
-- 0100 · Helpers
-- Zona horaria, aleatorio determinista (para seed reproducible), formato ES.
-- ═══════════════════════════════════════════════════════════════════════════

-- "Hoy" en El Salvador. NUNCA usar current_date: el servidor está en UTC y
-- entre 18:00 y 24:00 hora SV la fecha UTC ya es el día siguiente.
create or replace function sv_now() returns timestamp
language sql stable as $$ select (now() at time zone 'America/El_Salvador') $$;

create or replace function sv_today() returns date
language sql stable as $$ select (now() at time zone 'America/El_Salvador')::date $$;

-- Aleatorio determinista: misma llave → mismo número. Seed 100% reproducible.
create or replace function drand(p_key text) returns double precision
language sql immutable as $$
  select ('x' || substr(md5(p_key), 1, 12))::bit(48)::bigint::double precision / 281474976710656.0
$$;

create or replace function dint(p_key text, p_min int, p_max int) returns int
language sql immutable as $$
  select least(p_max, p_min + floor((p_max - p_min + 1) * drand(p_key))::int)
$$;

create or replace function dnum(p_key text, p_min numeric, p_max numeric) returns numeric
language sql immutable as $$
  select p_min + (p_max - p_min) * drand(p_key)::numeric
$$;

create or replace function dpick(p_key text, p_options text[]) returns text
language sql immutable as $$
  select p_options[1 + least(array_length(p_options, 1) - 1, floor(array_length(p_options, 1) * drand(p_key))::int)]
$$;

-- Lectura segura de jsonb
create or replace function jnum(j jsonb) returns numeric
language sql immutable as $$
  select case
    when j is null then null
    when jsonb_typeof(j) = 'number' then (j #>> '{}')::numeric
    when jsonb_typeof(j) = 'string' and (j #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j #>> '{}')::numeric
    else null end
$$;

create or replace function jbool(j jsonb) returns boolean
language sql immutable as $$
  select case
    when j is null then null
    when jsonb_typeof(j) = 'boolean' then (j #>> '{}')::boolean
    -- tri-estado: "unknown" / "" = sin evidencia → NULL (ni true ni false)
    when jsonb_typeof(j) = 'string' then case
         when lower(j #>> '{}') in ('true','si','sí','yes','1') then true
         when lower(j #>> '{}') in ('false','no','0') then false
         else null end
    when jsonb_typeof(j) = 'number' then (j #>> '{}')::numeric <> 0
    else null end
$$;

-- Formato para el cliente (voz y texto)
create or replace function fmt_money(p numeric) returns text
language sql immutable as $$
  select '$' || to_char(coalesce(p, 0), 'FM999,999,990.00')
$$;

create or replace function fmt_date_es(p date) returns text
language sql immutable as $$
  select case when p is null then null else
    (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow from p)::int]
    || ' ' || extract(day from p)::int || ' de ' ||
    (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
           'septiembre','octubre','noviembre','diciembre'])[extract(month from p)::int]
  end
$$;

-- Reemplaza {llave} por valor. Usado para términos de ofertas y prompts.
create or replace function render_template(p_template text, p_vars jsonb) returns text
language plpgsql immutable as $$
declare
  v_out text := p_template;
  r record;
begin
  if p_template is null then return null; end if;
  for r in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{' || r.key || '}', coalesce(r.value, ''));
  end loop;
  return v_out;
end $$;

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
