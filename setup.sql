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

create or replace function public.save_ldr_room(p_code text, p_token uuid, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; safe_state jsonb;
begin
  select * into r from ldr_rooms where code=upper(trim(p_code)) for update;
  if not found or (p_token<>r.token1 and p_token is distinct from r.token2) then
    raise exception 'Sesi tidak cocok dengan room ini.';
  end if;
  -- Client tidak dapat menghapus atau menambah kursi pemain melalui payload save.
  safe_state := p_state || jsonb_build_object('players',r.state->'players');
  -- Dua jawaban yang masuk hampir bersamaan tetap digabung selama pertanyaannya sama.
  if r.state->'round'->>'q' is not null
     and r.state->'round'->>'q' = p_state->'round'->>'q' then
    safe_state := jsonb_set(
      safe_state,
      '{round,answers}',
      coalesce(r.state->'round'->'answers','{}'::jsonb) || coalesce(p_state->'round'->'answers','{}'::jsonb),
      true
    );
  end if;
  update ldr_rooms set state=safe_state where code=r.code;
  return jsonb_build_object('ok',true);
end $$;

revoke all on function public.create_ldr_room(text,text) from public;
revoke all on function public.join_ldr_room(text,text,text) from public;
revoke all on function public.get_ldr_room(text,uuid) from public;
revoke all on function public.save_ldr_room(text,uuid,jsonb) from public;
grant execute on function public.create_ldr_room(text,text) to anon, authenticated;
grant execute on function public.join_ldr_room(text,text,text) to anon, authenticated;
grant execute on function public.get_ldr_room(text,uuid) to anon, authenticated;
grant execute on function public.save_ldr_room(text,uuid,jsonb) to anon, authenticated;
