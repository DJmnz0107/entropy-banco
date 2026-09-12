/**
 * Demo utilities — for hackathon demo only.
 *
 * POST /demo/set-contact  — habilita un personaje con un número real
 * GET  /demo/customers    — lista los 12 personajes DEMO-001..012
 */

import { Hono } from 'hono';
import { db, supabase } from '../lib/supabase.js';

export const demoRouter = new Hono();

demoRouter.post('/set-contact', async (c) => {
  try {
    const body = (await c.req.json()) as { customer_code: string; phone: string };
    if (!body.customer_code || !body.phone) {
      return c.json({ error: 'customer_code and phone are required' }, 400);
    }
    await db.setDemoContact(body.customer_code, body.phone);
    return c.json({ ok: true, message: `${body.customer_code} habilitado con ${body.phone}` });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ error: msg }, 500);
  }
});

demoRouter.get('/customers', async (c) => {
  try {
    const { data, error } = await supabase
      .from('v_customer_overview')
      .select('*')
      .like('customer_code', 'DEMO-%')
      .order('customer_code');

    if (error) throw new Error(error.message);
    return c.json({ customers: data });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ error: msg }, 500);
  }
});

// Reset demo data
demoRouter.post('/reset', async (c) => {
  try {
    const { error } = await supabase.rpc('reset_demo');
    if (error) throw new Error(error.message);
    return c.json({ ok: true, message: 'Demo reset completado' });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ error: msg }, 500);
  }
});
