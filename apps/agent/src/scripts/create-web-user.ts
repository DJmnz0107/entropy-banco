/** Crea (o actualiza) el usuario de Supabase Auth para entrar al dashboard.  npx tsx apps/agent/src/scripts/create-web-user.ts <email> <password> */
import { supabase } from '../lib/supabase.js';
const [email, password] = process.argv.slice(2);
if (!email || !password) throw new Error('Uso: create-web-user.ts <email> <password>');
const { data: list } = await supabase.auth.admin.listUsers({ page: 1, perPage: 200 });
const existing = list?.users.find((u) => u.email === email);
const res = existing
  ? await supabase.auth.admin.updateUserById(existing.id, { password, email_confirm: true })
  : await supabase.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { role: 'ventas', demo: true } });
if (res.error) throw new Error(res.error.message);
console.log(existing ? 'actualizado' : 'creado', res.data.user?.email);
process.exit(0);
