#!/usr/bin/env bash
# Sube migraciones + seed a Supabase SIN Docker.
# Requiere SUPABASE_DB_URL en .env (Dashboard → Connect → Session pooler, con la contraseña de la BD).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
: "${SUPABASE_DB_URL:?Falta SUPABASE_DB_URL en .env (Dashboard → Connect → Session pooler)}"
echo "▶ Probando localmente antes de subir…"
npm run --silent db:test > /dev/null && echo "✅ pruebas locales OK"
echo "▶ Migraciones pendientes:"
supabase db push --db-url "$SUPABASE_DB_URL" --dry-run
read -r -p "¿Aplicar migraciones + seed (reset_demo) en Supabase? [s/N] " ok
[ "$ok" = "s" ] || { echo "cancelado"; exit 0; }
supabase db push --db-url "$SUPABASE_DB_URL" --include-seed
echo "✅ Listo. Siguiente: select set_demo_contact('DEMO-001', '+503XXXXXXXX');"
