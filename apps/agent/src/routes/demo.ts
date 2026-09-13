/** Utilidades de demo (protegidas con AGENT_SHARED_SECRET). */
import { Hono } from 'hono';
import { rpc, supabase } from '../lib/supabase.js';
import { requireAgentSecret } from './auth.js';

export const demoRouter = new Hono();
demoRouter.use('*', requireAgentSecret);

demoRouter.post('/set-contact', async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { customer_code?: string; phone?: string; email?: string };
  if (!body.customer_code || !body.phone) return c.json({ error: 'customer_code y phone son obligatorios' }, 400);
  try {
    await rpc('set_demo_contact', { p_customer_code: body.customer_code, p_phone: body.phone, p_email: body.email ?? null });
    return c.json({ ok: true, message: `${body.customer_code} habilitado con ${body.phone}${body.email ? ` y ${body.email}` : ''}` });
  } catch (err) {
    return c.json({ error: (err as Error).message }, 500);
  }
});

demoRouter.get('/customers', async (c) => {
  const { data, error } = await supabase.from('v_customer_overview').select('*').like('customer_code', 'DEMO-%').order('customer_code');
  if (error) return c.json({ error: error.message }, 500);
  return c.json({ customers: data });
});

demoRouter.post('/reset', async (c) => {
  try {
    const result = await rpc('reset_demo');
    return c.json({ ok: true, result });
  } catch (err) {
    return c.json({ error: (err as Error).message }, 500);
  }
});
