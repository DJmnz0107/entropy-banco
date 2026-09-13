/**
 * POST /runs                      corrida con datos actuales + despacho (lo llama "Iniciar corrida" de la web)
 * POST /runs/:runId/dispatch      despachar una corrida ya calculada
 * POST /calls/:customerId         llamar a UN cliente ("Empezar llamada")  body: { simulate?: boolean, scenario?: "ESC-C" }
 */
import { Hono } from 'hono';
import { providers } from '../config.js';
import { db } from '../lib/supabase.js';
import { planAndDispatch, startRealCall } from '../channels/dispatch.js';
import { loadScenario, runSimulatedCall } from '../channels/simulated-call.js';
import { requireAgentSecret } from './auth.js';

export const runsRouter = new Hono();
// Solo estas rutas llevan secreto (este router se monta en '/': un use('*') bloquearía también el Custom LLM y los webhooks)
runsRouter.use('/runs', requireAgentSecret);
runsRouter.use('/runs/*', requireAgentSecret);
runsRouter.use('/calls/*', requireAgentSecret);

const DEFAULT_FILTERS = { grades: ['A', 'B', 'C', 'D', 'E'], max_days_to_due: 10 };

runsRouter.post('/runs', async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { filters?: Record<string, unknown>; dispatch?: boolean; created_by?: string };
  try {
    const run = await db.runPrevention({ ...DEFAULT_FILTERS, ...(body.filters ?? {}) }, body.created_by ?? 'web');
    const dispatch = body.dispatch === false ? null : await planAndDispatch(run.run_id);
    return c.json({ ok: true, run, dispatch });
  } catch (err) {
    return c.json({ ok: false, error: (err as Error).message }, 500);
  }
});

runsRouter.post('/runs/:runId/dispatch', async (c) => {
  try {
    return c.json({ ok: true, dispatch: await planAndDispatch(c.req.param('runId')) });
  } catch (err) {
    return c.json({ ok: false, error: (err as Error).message }, 500);
  }
});

runsRouter.post('/calls/:customerId', async (c) => {
  const customerId = c.req.param('customerId');
  const body = (await c.req.json().catch(() => ({}))) as { simulate?: boolean; scenario?: string };
  try {
    const intervention = await db.interventionForCustomer(customerId);
    const contact = await db.customerContact(customerId);
    if (!contact) return c.json({ ok: false, error: 'Cliente no encontrado' }, 404);

    const wantsReal = !body.simulate && providers.voice() === 'elevenlabs';
    if (wantsReal) {
      if (!contact.contact_enabled) return c.json({ ok: false, error: `${contact.customer_code} no tiene contacto habilitado (set_demo_contact).` }, 400);
      const ctx = await db.context(customerId);
      const call = await startRealCall({
        customer_id: customerId, intervention_id: intervention?.id ?? '', phone_e164: contact.phone_e164,
        first_name: contact.first_name, full_name: contact.full_name, grade: intervention?.grade ?? '',
        amount_due_text: ctx.loan?.amount_due_text ?? '', due_date_text: ctx.loan?.next_due_date_text ?? '',
      });
      return c.json({ ok: true, mode: 'elevenlabs', ...call });
    }

    const scenario = body.scenario ? await loadScenario(body.scenario) : undefined;
    const promise = runSimulatedCall(customerId, intervention?.id ?? null, scenario);
    // devolvemos el id apenas exista la conversación; la llamada sigue en segundo plano
    const conversationId = await new Promise<string | null>((resolve) => {
      const poll = setInterval(async () => {
        const { data } = await (await import('../lib/supabase.js')).supabase.from('conversations').select('id')
          .eq('customer_id', customerId).eq('status', 'active').eq('channel', 'voice').order('started_at', { ascending: false }).limit(1).maybeSingle();
        if (data) { clearInterval(poll); resolve((data as { id: string }).id); }
      }, 400);
      setTimeout(() => { clearInterval(poll); resolve(null); }, 8000);
    });
    promise.catch((err) => console.warn(`[calls] simulada ${customerId}: ${(err as Error).message}`));
    return c.json({ ok: true, mode: 'simulated', conversationId });
  } catch (err) {
    return c.json({ ok: false, error: (err as Error).message }, 500);
  }
});
