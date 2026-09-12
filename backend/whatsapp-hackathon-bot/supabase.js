import { createClient } from '@supabase/supabase-js';

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY);

export async function getHistory(phoneNumber) {
  const { data, error } = await supabase
    .from('conversations')
    .select('history')
    .eq('phone_number', phoneNumber)
    .maybeSingle();

  if (error) throw error;
  return data?.history ?? [];
}

export async function saveHistory(phoneNumber, history) {
  const { error } = await supabase
    .from('conversations')
    .upsert({ phone_number: phoneNumber, history, updated_at: new Date().toISOString() });

  if (error) throw error;
}
