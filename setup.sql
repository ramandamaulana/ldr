-- Jauh Dekat: backend room dua pemain.
-- Jalankan sekali di Supabase Dashboard > SQL Editor.
create table if not exists public.ldr_rooms (
  code text primary key check (code ~ '^[A-Z2-9]{6}$'),
  token1 uuid not null,
  token2 uuid,
  state jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.ldr_rooms enable row level security;
revoke all on public.ldr_rooms from anon, authenticated;

create or replace function public.create_ldr_room(p_name text, p_avatar text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  new_code text;
  t uuid := gen_random_uuid();
  new_state jsonb;
  i integer;
begin
  if length(trim(coalesce(p_name,''))) < 1 or length(p_name) > 20 then
    raise exception 'Nama panggilan harus 1-20 karakter.';
  end if;
  loop
    new_code := '';
    for i in 1..6 loop
      new_code := new_code || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
    end loop;
    exit when not exists(select 1 from ldr_rooms where code = new_code);
  end loop;
  new_state := jsonb_build_object(
    'players', jsonb_build_array(jsonb_build_object('name',trim(p_name),'avatar',left(p_avatar,8),'slot',0)),
    'mode','deep','async',false,'xp',0,'streak',0,'lastDay','','startDate','','meetDate','',
    'history','[]'::jsonb,'jar','[]'::jsonb,'used','[]'::jsonb,'turn',0,'round','{}'::jsonb,
    'custom','[]'::jsonb,'questions','[]'::jsonb,'story','[]'::jsonb,'quiz','[]'::jsonb,'ldrSince','','deepOn',true
  );
  insert into ldr_rooms(code,token1,state) values(new_code,t,new_state);
  return jsonb_build_object('code',new_code,'token',t,'slot',0,'state',new_state);
end $$;

create or replace function public.join_ldr_room(p_code text, p_name text, p_avatar text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; t uuid := gen_random_uuid(); updated jsonb;
begin
  if length(trim(coalesce(p_name,''))) < 1 or length(p_name) > 20 then
    raise exception 'Nama panggilan harus 1-20 karakter.';
  end if;
  select * into r from ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Kode room tidak ditemukan. Cek lagi ya.'; end if;
  if r.token2 is not null then raise exception 'Room ini sudah berisi dua pemain 💗'; end if;
  updated := jsonb_set(r.state,'{players}',(r.state->'players') || jsonb_build_array(jsonb_build_object('name',trim(p_name),'avatar',left(p_avatar,8),'slot',1)));
  update ldr_rooms set token2=t,state=updated where code=r.code;
  return jsonb_build_object('code',r.code,'token',t,'slot',1,'state',updated);
end $$;

create or replace function public.get_ldr_room(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer;
begin
  select * into r from ldr_rooms where code=upper(trim(p_code));
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0;
  elsif p_token=r.token2 then player_slot:=1;
  else raise exception 'Sesi tidak cocok dengan room ini.'; end if;
  return jsonb_build_object('code',r.code,'slot',player_slot,'state',r.state);
end $$;

-- Deep merge untuk map state: jawaban/reaksi dari dua perangkat tidak saling
-- menghapus key milik pemain lain. Array tetap diganti dan di-union khusus di bawah.
create or replace function public.ldr_jsonb_deep_merge(old_value jsonb, new_value jsonb)
returns jsonb language plpgsql immutable set search_path = public, pg_temp as $$
declare result jsonb := coalesce(old_value,'{}'::jsonb); k text; v jsonb;
begin
  if jsonb_typeof(old_value) <> 'object' or jsonb_typeof(new_value) <> 'object' then
    return coalesce(new_value,old_value,'null'::jsonb);
  end if;
  for k,v in select key,value from jsonb_each(new_value) loop
    if result ? k then
      result := jsonb_set(result,array[k],public.ldr_jsonb_deep_merge(result->k,v),true);
    else
      result := jsonb_set(result,array[k],v,true);
    end if;
  end loop;
  return result;
end $$;

create or replace function public.save_ldr_room(p_code text, p_token uuid, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; safe_state jsonb; player_slot integer; old_round jsonb; new_round jsonb;
  v_history jsonb; v_jar jsonb; v_story jsonb;
begin
  select * into r from ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Sesi tidak cocok dengan room ini.'; end if;
  if p_token=r.token1 then player_slot:=0;
  elsif p_token=r.token2 then player_slot:=1;
  else raise exception 'Sesi tidak cocok dengan room ini.'; end if;

  -- Gabungkan map secara rekursif, lalu lindungi identitas dan daftar kursi room.
  safe_state := public.ldr_jsonb_deep_merge(r.state,p_state);
  safe_state := jsonb_set(safe_state,'{players}',r.state->'players',true);

  -- Round hanya digabung jika ID ronde sama; ronde baru boleh mengganti jawaban lama.
  old_round:=coalesce(r.state->'round','{}'::jsonb);
  new_round:=coalesce(p_state->'round','{}'::jsonb);
  if old_round->>'id' is not null and old_round->>'id'=new_round->>'id' then
    new_round:=public.ldr_jsonb_deep_merge(old_round,new_round);
  end if;
  safe_state:=jsonb_set(safe_state,'{round}',new_round,true);

  -- Pertahankan map-array historis dari kedua perangkat agar save yang berdekatan
  -- tidak menghilangkan Memory Jar, album cerita, atau riwayat jawaban.
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_history
  from (select value from jsonb_array_elements(coalesce(r.state->'history','[]'::jsonb))
        union select value from jsonb_array_elements(coalesce(p_state->'history','[]'::jsonb))) x;
  safe_state:=jsonb_set(safe_state,'{history}',v_history,true);
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_jar
  from (select value from jsonb_array_elements(coalesce(r.state->'jar','[]'::jsonb))
        union select value from jsonb_array_elements(coalesce(p_state->'jar','[]'::jsonb))) x;
  safe_state:=jsonb_set(safe_state,'{jar}',v_jar,true);
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_story
  from (select value from jsonb_array_elements(coalesce(r.state->'story','[]'::jsonb))
        union select value from jsonb_array_elements(coalesce(p_state->'story','[]'::jsonb))) x;
  safe_state:=jsonb_set(safe_state,'{story}',v_story,true);
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_history
  from (select value from jsonb_array_elements(coalesce(r.state->'used','[]'::jsonb))
        union select value from jsonb_array_elements(coalesce(p_state->'used','[]'::jsonb))) x;
  safe_state:=jsonb_set(safe_state,'{used}',v_history,true);
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_jar
  from (select value from jsonb_array_elements(coalesce(r.state->'custom','[]'::jsonb))
        union select value from jsonb_array_elements(coalesce(p_state->'custom','[]'::jsonb))) x;
  safe_state:=jsonb_set(safe_state,'{custom}',v_jar,true);

  update ldr_rooms set state=safe_state where code=r.code;
  return jsonb_build_object('ok',true);
end $$;

revoke all on function public.create_ldr_room(text,text) from public;
revoke all on function public.join_ldr_room(text,text,text) from public;
revoke all on function public.get_ldr_room(text,uuid) from public;
revoke all on function public.save_ldr_room(text,uuid,jsonb) from public;
revoke all on function public.ldr_jsonb_deep_merge(jsonb,jsonb) from public;
grant execute on function public.create_ldr_room(text,text) to anon, authenticated;
grant execute on function public.join_ldr_room(text,text,text) to anon, authenticated;
grant execute on function public.get_ldr_room(text,uuid) to anon, authenticated;
grant execute on function public.save_ldr_room(text,uuid,jsonb) to anon, authenticated;
