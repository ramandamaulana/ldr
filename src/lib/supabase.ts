import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export type BackendConfig = { url: string; key: string };
let clientPromise: Promise<SupabaseClient> | undefined;

export async function getBackendConfig(): Promise<BackendConfig> {
  const response = await fetch('/.well-known/ldr-config', { cache: 'no-store' });
  if (!response.ok) throw new Error('Konfigurasi Supabase belum bisa dibaca dari server.');
  const config = await response.json() as Partial<BackendConfig>;
  if (!config.url || !config.key) throw new Error('Isi SUPABASE_URL dan SUPABASE_PUBLISHABLE_KEY di environment hosting.');
  return { url: config.url, key: config.key };
}

export function getSupabase(): Promise<SupabaseClient> {
  clientPromise ??= getBackendConfig().then(({ url, key }) => createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' },
    realtime: { params: { eventsPerSecond: 4 } },
    global: { fetch: async (input, init) => {
      const controller=new AbortController();
      const timer=window.setTimeout(()=>controller.abort(new DOMException('Server tidak merespons dalam 20 detik.','TimeoutError')),20_000);
      const cancel=()=>controller.abort(init?.signal?.reason);
      init?.signal?.addEventListener('abort',cancel,{once:true});
      try{return await fetch(input,{...init,signal:controller.signal})}
      finally{window.clearTimeout(timer);init?.signal?.removeEventListener('abort',cancel)}
    } },
  }));
  return clientPromise;
}

export function resetSupabaseClientForTests() { clientPromise = undefined; }
