import { useEffect, useState } from 'react';
import type { SupabaseClient, User } from '@supabase/supabase-js';
import { getSupabase } from '../../lib/supabase';
import { messageOf } from '../../lib/errors';

export function useAuthSession() {
  const [client,setClient] = useState<SupabaseClient | null>(null);
  const [user,setUser] = useState<User | null>(null);
  const [ready,setReady] = useState(false);
  const [error,setError] = useState('');
  useEffect(() => {
    let live = true;
    let unsubscribe = () => {};
    getSupabase().then((supabase) => {
      if (!live) return;
      setClient(supabase);
      const { data } = supabase.auth.onAuthStateChange((_event, session) => {
        if (!live) return;
        setUser(session?.user ?? null);
        setReady(true);
      });
      unsubscribe = () => data.subscription.unsubscribe();
      return supabase.auth.getSession().then(({ data: sessionData, error: sessionError }) => {
        if (!live) return;
        if (sessionError) setError(sessionError.message);
        setUser(sessionData.session?.user ?? null);
        setReady(true);
      });
    }).catch((reason: unknown) => { if (live) { setError(messageOf(reason)); setReady(true); } });
    return () => { live = false; unsubscribe(); };
  },[]);
  return { client,user,ready,error,setError };
}
