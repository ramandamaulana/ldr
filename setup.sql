-- Jauh Dekat v2: run once in Supabase SQL Editor after enabling Auth providers.
-- Existing ldr_rooms data is kept intact; the old token-based RPCs are revoked below.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Teman',
  avatar text not null default '🐻',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 24)
);

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  status text not null default 'waiting' check (status in ('waiting','ready','playing','closed')),
  created_by uuid not null references auth.users(id),
  settings jsonb not null default '{"async":false,"deep_enabled":true,"ldr_since":null,"meet_date":null,"custom_questions":[]}'::jsonb,
  xp integer not null default 0 check (xp >= 0),
  streak integer not null default 0 check (streak >= 0),
  last_played_on date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.rooms alter column settings set default '{"async":false,"deep_enabled":true,"ldr_since":null,"meet_date":null,"custom_questions":[]}'::jsonb;

create table if not exists public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  seat smallint not null check (seat in (0,1)),
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (room_id,user_id),
  unique (room_id,seat),
  unique (user_id)
);

create table if not exists public.room_join_attempts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  attempts integer not null default 0 check (attempts>=0)
);

create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_type text not null check (game_type in ('guess_me','would_you_rather','deep_talk','hot_takes','ldr_challenge','couple_quiz','dream_date','story_chain','tic_tac_toe','snakes_ladders')),
  status text not null default 'playing' check (status in ('playing','round_complete','finished')),
  round_no integer not null default 1 check (round_no > 0),
  state jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.game_sessions add column if not exists question_id text;
create unique index if not exists game_sessions_one_active_per_room
  on public.game_sessions(room_id) where status in ('playing','round_complete');

create table if not exists public.game_actions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.game_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  action_type text not null,
  created_at timestamptz not null default now(),
  unique(session_id,idempotency_key)
);
create table if not exists public.room_question_uses (
  room_id uuid not null references public.rooms(id) on delete cascade,
  question_id text not null,
  used_at timestamptz not null default now(),
  primary key(room_id,question_id)
);
alter table public.room_question_uses enable row level security;

create table if not exists public.room_memories (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  body text not null check (char_length(body) between 1 and 800),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_join_attempts enable row level security;
alter table public.game_sessions enable row level security;
alter table public.game_actions enable row level security;
alter table public.room_memories enable row level security;

drop policy if exists profiles_read_room on public.profiles;
create policy profiles_read_room on public.profiles for select to authenticated using (id = (select auth.uid()));
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
drop policy if exists rooms_read_member on public.rooms;
create policy rooms_read_member on public.rooms for select to authenticated
  using (exists (select 1 from public.room_members m where m.room_id = rooms.id and m.user_id = (select auth.uid())));
drop policy if exists members_read_room on public.room_members;
create policy members_read_room on public.room_members for select to authenticated
  using (user_id = (select auth.uid()));
-- Sessions are deliberately readable through get_my_room() only so private answers can be projected safely.
drop policy if exists sessions_read_member on public.game_sessions;
drop policy if exists actions_read_member on public.game_actions;
drop policy if exists memories_read_member on public.room_memories;
create policy memories_read_member on public.room_memories for select to authenticated
  using (exists (select 1 from public.room_members m where m.room_id = room_memories.room_id and m.user_id = (select auth.uid())));
drop policy if exists memories_insert_member on public.room_memories;
create policy memories_insert_member on public.room_memories for insert to authenticated
  with check (created_by = (select auth.uid()) and exists (select 1 from public.room_members m where m.room_id = room_memories.room_id and m.user_id = (select auth.uid())));

create or replace function public.touch_profile_from_auth()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id,display_name,avatar)
  values (new.id,coalesce(nullif(left(new.raw_user_meta_data->>'full_name',24),''),'Teman'),coalesce(nullif(left(new.raw_user_meta_data->>'avatar',8),''),'🐻'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists auth_user_profile on auth.users;
create trigger auth_user_profile after insert on auth.users for each row execute function public.touch_profile_from_auth();

create or replace function public.create_ldr_room(p_display_name text,p_avatar text,p_ldr_since date default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); room_id uuid; room_code text; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; raw bytea; i int; tries int := 0;
begin
  if uid is null then raise exception 'Login dulu sebelum membuat room.' using errcode='28000'; end if;
  if char_length(trim(coalesce(p_display_name,''))) not between 1 and 24 then raise exception 'Nama harus 1–24 karakter.'; end if;
  insert into public.profiles(id,display_name,avatar) values(uid,trim(p_display_name),left(coalesce(p_avatar,'🐻'),8))
    on conflict(id) do update set display_name=excluded.display_name,avatar=excluded.avatar,updated_at=now();
  if exists(select 1 from public.room_members where user_id=uid) then raise exception 'Akun ini sudah terhubung ke satu room.'; end if;
  loop
    tries := tries + 1; raw := extensions.gen_random_bytes(6); room_code := '';
    for i in 0..5 loop room_code := room_code || substr(alphabet,(get_byte(raw,i)%32)+1,1); end loop;
    insert into public.rooms(code,created_by,settings) values(room_code,uid,jsonb_set('{"async":false,"deep_enabled":true,"ldr_since":null,"meet_date":null,"custom_questions":[]}'::jsonb,'{ldr_since}',coalesce(to_jsonb(p_ldr_since), 'null'::jsonb)))
      on conflict(code) do nothing returning id into room_id;
    exit when room_id is not null;
    if tries > 5 then raise exception 'Belum bisa membuat kode room. Coba lagi ya.'; end if;
  end loop;
  insert into public.room_members(room_id,user_id,seat) values(room_id,uid,0);
  return jsonb_build_object('room_id',room_id,'code',room_code,'seat',0);
end $$;

create or replace function public.join_ldr_room(p_code text,p_display_name text,p_avatar text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r public.rooms%rowtype; member_count int; seat_no int; limit_row public.room_join_attempts%rowtype;
begin
  if uid is null then raise exception 'Login dulu sebelum bergabung.' using errcode='28000'; end if;
  if char_length(trim(coalesce(p_display_name,''))) not between 1 and 24 then raise exception 'Nama harus 1–24 karakter.'; end if;
  if exists(select 1 from public.room_members where user_id=uid) then
    select room_id,seat into r.id,seat_no from public.room_members where user_id=uid;
    select code into r.code from public.rooms where id=r.id;
    return jsonb_build_object('room_id',r.id,'code',r.code,'seat',seat_no);
  end if;
  insert into public.room_join_attempts(user_id) values(uid) on conflict(user_id) do nothing;
  select * into limit_row from public.room_join_attempts where user_id=uid for update;
  if limit_row.window_started_at<now()-interval '15 minutes' then
    update public.room_join_attempts set window_started_at=now(),attempts=0 where user_id=uid;
  elsif limit_row.attempts>=10 then return jsonb_build_object('error_code','join_rate_limited');
  end if;
  update public.room_join_attempts set attempts=attempts+1 where user_id=uid;
  select * into r from public.rooms where code=upper(trim(coalesce(p_code,''))) and status in ('waiting','ready') for update;
  if not found then return jsonb_build_object('error_code','room_not_found'); end if;
  if exists(select 1 from public.room_members where room_id=r.id and user_id=uid) then raise exception 'Kamu sudah ada di room ini.'; end if;
  select count(*) into member_count from public.room_members where room_id=r.id;
  if member_count >= 2 then return jsonb_build_object('error_code','room_full'); end if;
  seat_no := case when exists(select 1 from public.room_members where room_id=r.id and seat=0) then 1 else 0 end;
  insert into public.profiles(id,display_name,avatar) values(uid,trim(p_display_name),left(coalesce(p_avatar,'🐻'),8))
    on conflict(id) do update set display_name=excluded.display_name,avatar=excluded.avatar,updated_at=now();
  insert into public.room_members(room_id,user_id,seat) values(r.id,uid,seat_no);
  update public.rooms set status='ready',updated_at=now() where id=r.id;
  return jsonb_build_object('room_id',r.id,'code',r.code,'seat',seat_no);
end $$;

create or replace function public.get_my_room()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); rid uuid; seat_no int; r public.rooms%rowtype; session_row public.game_sessions%rowtype; roster jsonb; session_json jsonb;
begin
  if uid is null then raise exception 'Sesi login tidak ditemukan.' using errcode='28000'; end if;
  select m.room_id,m.seat into rid,seat_no from public.room_members m where m.user_id=uid;
  if rid is null then return null; end if;
  select * into r from public.rooms where id=rid;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.display_name,'avatar',p.avatar,'seat',m.seat) order by m.seat),'[]'::jsonb)
    into roster from public.room_members m join public.profiles p on p.id=m.user_id where m.room_id=rid;
  select * into session_row from public.game_sessions where room_id=rid and status in ('playing','round_complete') order by created_at desc limit 1;
  session_json := null;
  if session_row.id is not null then
    session_json := to_jsonb(session_row);
    if session_row.game_type='guess_me' and session_row.state->>'guess_answer' is null
      and seat_no<>(session_row.state->>'owner_seat')::integer then
      session_json := jsonb_set(session_json,'{state}',session_row.state-'secret_answer',true);
    end if;
  end if;
  return jsonb_build_object('room',jsonb_build_object('id',r.id,'code',r.code,'status',r.status,'created_by',r.created_by,'settings',r.settings,'xp',r.xp,'streak',r.streak,'last_played_on',r.last_played_on,'created_at',r.created_at,'updated_at',r.updated_at),'seat',seat_no,'members',roster,'game',session_json);
end $$;

create or replace function public.start_ldr_game(p_game_type text,p_prompt text default null,p_options jsonb default null,p_action_id uuid default gen_random_uuid(),p_question_id text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); rid uuid; r public.rooms%rowtype; sid uuid; gs public.game_sessions%rowtype; state_json jsonb; player_a uuid; player_b uuid; owner_no int := 0;
begin
  if uid is null then raise exception 'Login diperlukan.' using errcode='28000'; end if;
  select m.room_id into rid from public.room_members m where m.user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  select * into r from public.rooms where id=rid for update;
  if (select count(*) from public.room_members where room_id=rid)<>2 then raise exception 'Tunggu pasanganmu masuk dulu ya 💗'; end if;
  select id into sid from public.game_sessions where room_id=rid and status in ('playing','round_complete') limit 1;
  if sid is not null then select * into gs from public.game_sessions where id=sid; return to_jsonb(gs); end if;
  if p_game_type not in ('guess_me','would_you_rather','deep_talk','hot_takes','ldr_challenge','couple_quiz','dream_date','story_chain','tic_tac_toe','snakes_ladders') then raise exception 'Mode game tidak dikenal.'; end if;
  if p_prompt is not null and char_length(p_prompt)>500 then raise exception 'Pertanyaan terlalu panjang.'; end if;
  if jsonb_typeof(coalesce(p_options,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_options,'[]'::jsonb))>8 then raise exception 'Pilihan game tidak valid.'; end if;
  if p_question_id is not null and exists(select 1 from public.room_question_uses where room_id=rid and question_id=p_question_id) then raise exception 'Pertanyaan ini sudah pernah kalian jawab. Acak kartu yang lain ya.'; end if;
  if p_game_type='guess_me' then select (count(*)%2)::int into owner_no from public.game_sessions where room_id=rid and game_type='guess_me'; end if;
  state_json := jsonb_build_object('prompt',coalesce(p_prompt,''),'options',coalesce(p_options,'[]'::jsonb),'answers','{}'::jsonb,'votes','{}'::jsonb,'messages','[]'::jsonb,'board',case when p_game_type='tic_tac_toe' then '[null,null,null,null,null,null,null,null,null]'::jsonb else '[]'::jsonb end,'turn_seat',0,'owner_seat',owner_no,'round',1,'punishment',null);
  select user_id into player_a from public.room_members where room_id=rid and seat=0;
  select user_id into player_b from public.room_members where room_id=rid and seat=1;
  if p_game_type='snakes_ladders' then state_json:=jsonb_set(state_json,'{positions}',jsonb_build_object(player_a::text,1,player_b::text,1),true); end if;
  insert into public.game_sessions(room_id,game_type,created_by,state,question_id) values(rid,p_game_type,uid,state_json,p_question_id) returning * into gs;
  update public.rooms set status='playing',updated_at=now() where id=rid;
  return to_jsonb(gs);
end $$;

create or replace function public.submit_ldr_action(p_session_id uuid,p_idempotency_key uuid,p_action_type text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); gs public.game_sessions%rowtype; seat_no int; k text; state_json jsonb; answers jsonb; votes jsonb; messages jsonb; board jsonb; cell_no int; mark text; winner text; roll_no int; pos int; landed int; rawpos int; pun jsonb;
begin
  if uid is null then raise exception 'Login diperlukan.' using errcode='28000'; end if;
  if p_idempotency_key is null then raise exception 'ID aksi wajib diisi.'; end if;
  if char_length(coalesce(p_action_type,''))>40 or jsonb_typeof(coalesce(p_payload,'{}'::jsonb))<>'object' then raise exception 'Aksi tidak valid.'; end if;
  select m.seat into seat_no from public.room_members m join public.game_sessions s on s.room_id=m.room_id where s.id=p_session_id and m.user_id=uid;
  if seat_no is null then raise exception 'Kamu bukan anggota sesi ini.' using errcode='42501'; end if;
  select * into gs from public.game_sessions where id=p_session_id for update;
  if gs.status<>'playing' and not (gs.status='round_complete' and p_action_type='rematch' and gs.game_type='tic_tac_toe') then raise exception 'Sesi ini sudah selesai.'; end if;
  if exists(select 1 from public.game_actions where session_id=gs.id and idempotency_key=p_idempotency_key) then return to_jsonb(gs); end if;
  insert into public.game_actions(session_id,user_id,idempotency_key,action_type) values(gs.id,uid,p_idempotency_key,p_action_type);
  state_json:=gs.state; k:=uid::text; answers:=coalesce(state_json->'answers','{}'::jsonb); votes:=coalesce(state_json->'votes','{}'::jsonb); messages:=coalesce(state_json->'messages','[]'::jsonb);
  if p_action_type in ('answer','vote','complete','contribute') then
    if p_action_type='answer' and gs.game_type='guess_me' then
      if char_length(trim(coalesce(p_payload->>'text',''))) not between 1 and 500 then raise exception 'Isi jawaban singkat dulu ya.'; end if;
      if seat_no=(state_json->>'owner_seat')::integer then
        if state_json ? 'secret_answer' then raise exception 'Jawaban rahasia sudah tersimpan.'; end if;
        state_json:=jsonb_set(state_json,'{secret_answer}',to_jsonb(trim(p_payload->>'text')),true);
      else
        if state_json->>'secret_answer' is null then raise exception 'Tunggu pasanganmu menyiapkan jawabannya dulu.'; end if;
        if state_json ? 'guess_answer' then raise exception 'Tebakanmu sudah tersimpan.'; end if;
        state_json:=jsonb_set(state_json,'{guess_answer}',to_jsonb(trim(p_payload->>'text')),true);
        gs.status:='round_complete';
        update public.rooms set xp=xp+5,streak=case when last_played_on=current_date then streak when last_played_on=current_date-1 then streak+1 else 1 end,last_played_on=current_date,updated_at=now() where id=gs.room_id;
        if gs.question_id is not null then insert into public.room_question_uses(room_id,question_id) values(gs.room_id,gs.question_id) on conflict do nothing; end if;
      end if;
    elsif p_action_type='vote' then
      if answers ? k then raise exception 'Pilihanmu sudah tersimpan.'; end if;
      if gs.game_type not in ('would_you_rather','hot_takes') then raise exception 'Voting tidak tersedia di mode ini.'; end if;
      if gs.game_type='would_you_rather' and coalesce(p_payload->>'choice','') not in ('0','1') then raise exception 'Pilihan tidak valid.'; end if;
      if gs.game_type='hot_takes' and coalesce(p_payload->>'choice','') not in ('0','1','2') then raise exception 'Pilihan tidak valid.'; end if;
      answers:=jsonb_set(answers,array[k],coalesce(p_payload->'choice',p_payload->'text'),true);
    elsif p_action_type in ('answer','complete','contribute') then
      if answers ? k then raise exception 'Jawabanmu sudah tersimpan.'; end if;
      if char_length(trim(coalesce(p_payload->>'text',''))) not between 1 and 800 then raise exception 'Jawabannya perlu diisi dulu ya.'; end if;
      answers:=jsonb_set(answers,array[k],to_jsonb(trim(p_payload->>'text')),true);
    end if;
    state_json:=jsonb_set(state_json,'{answers}',answers,true);
    if jsonb_object_length(answers)>=2 and gs.game_type not in ('hot_takes','guess_me') then
      gs.status:='round_complete';
      update public.rooms set xp=xp+5,streak=case when last_played_on=current_date then streak when last_played_on=current_date-1 then streak+1 else 1 end,last_played_on=current_date,updated_at=now() where id=gs.room_id;
      if gs.question_id is not null then insert into public.room_question_uses(room_id,question_id) values(gs.room_id,gs.question_id) on conflict do nothing; end if;
    elsif jsonb_object_length(answers)>=2 and gs.game_type='hot_takes' and state_json->>'rewarded' is distinct from 'true' then
      state_json:=jsonb_set(state_json,'{rewarded}','true'::jsonb,true);
      update public.rooms set xp=xp+5,streak=case when last_played_on=current_date then streak when last_played_on=current_date-1 then streak+1 else 1 end,last_played_on=current_date,updated_at=now() where id=gs.room_id;
      if gs.question_id is not null then insert into public.room_question_uses(room_id,question_id) values(gs.room_id,gs.question_id) on conflict do nothing; end if;
    end if;
  elsif p_action_type='chat' then
    if gs.game_type not in ('hot_takes','deep_talk','story_chain','dream_date') then raise exception 'Chat tidak tersedia di mode ini.'; end if;
    if char_length(trim(coalesce(p_payload->>'text',''))) not between 1 and 500 then raise exception 'Pesan kosong atau terlalu panjang.'; end if;
    if jsonb_array_length(messages)>=100 then raise exception 'Sesi chat sudah cukup panjang. Mulai ronde baru yuk.'; end if;
    messages:=messages||jsonb_build_array(jsonb_build_object('user_id',uid,'text',trim(p_payload->>'text'),'at',now()));
    state_json:=jsonb_set(state_json,'{messages}',messages,true);
  elsif p_action_type='move' and gs.game_type='tic_tac_toe' then
    cell_no:=nullif(p_payload->>'cell','')::integer;
    if cell_no is null or cell_no not between 0 and 8 then raise exception 'Kotak tidak valid.'; end if;
    if coalesce((state_json->>'turn_seat')::integer,-1)<>seat_no then raise exception 'Belum giliranmu.'; end if;
    board:=state_json->'board'; if board->cell_no is not null and board->cell_no<>'null'::jsonb then raise exception 'Kotak itu sudah terisi.'; end if;
    mark:=case when seat_no=0 then '❤️' else '💙' end; board:=jsonb_set(board,array[cell_no::text],to_jsonb(mark),false);
    winner:=null;
    if (board->0=board->1 and board->1=board->2 and board->0<>'null'::jsonb) or (board->3=board->4 and board->4=board->5 and board->3<>'null'::jsonb) or (board->6=board->7 and board->7=board->8 and board->6<>'null'::jsonb) or (board->0=board->3 and board->3=board->6 and board->0<>'null'::jsonb) or (board->1=board->4 and board->4=board->7 and board->1<>'null'::jsonb) or (board->2=board->5 and board->5=board->8 and board->2<>'null'::jsonb) or (board->0=board->4 and board->4=board->8 and board->0<>'null'::jsonb) or (board->2=board->4 and board->4=board->6 and board->2<>'null'::jsonb) then winner:=mark; end if;
    state_json:=jsonb_set(state_json,'{board}',board,true); state_json:=jsonb_set(state_json,'{turn_seat}',to_jsonb(1-seat_no),true);
    if winner is not null then state_json:=jsonb_set(state_json,'{winner}',to_jsonb(winner),true); gs.status:='round_complete'; update public.rooms set xp=xp+10,streak=case when last_played_on=current_date then streak when last_played_on=current_date-1 then streak+1 else 1 end,last_played_on=current_date,updated_at=now() where id=gs.room_id;
    elsif not exists(select 1 from jsonb_array_elements(board) as cells(value) where value='null'::jsonb) then state_json:=jsonb_set(state_json,'{winner}','"seri"'::jsonb,true); gs.status:='round_complete'; end if;
  elsif p_action_type='rematch' and gs.game_type='tic_tac_toe' then
    if gs.status<>'round_complete' then raise exception 'Ronde belum selesai.'; end if;
    state_json:=jsonb_set(state_json,'{board}','[null,null,null,null,null,null,null,null,null]'::jsonb,true); state_json:=state_json-'winner'; state_json:=jsonb_set(state_json,'{turn_seat}',to_jsonb(1-(coalesce((state_json->>'turn_seat')::integer,1-seat_no))),true); gs.status:='playing'; gs.round_no:=gs.round_no+1;
  elsif p_action_type='roll' and gs.game_type='snakes_ladders' then
    if coalesce((state_json->>'turn_seat')::integer,-1)<>seat_no then raise exception 'Belum giliranmu.'; end if;
    if state_json->'punishment'->>'status'='active' then raise exception 'Selesaikan tantangan dulu sebelum melempar.'; end if;
    roll_no:=1+floor(random()*6)::int; pos:=coalesce((state_json->'positions'->>k)::int,1); landed:=pos+roll_no;
    if landed>100 then landed:=pos; end if;
    rawpos:=landed;
    if landed in (4,9,20,28,40,63,71) then landed:=case landed when 4 then 14 when 9 then 31 when 20 then 38 when 28 then 84 when 40 then 59 when 63 then 81 else 91 end;
    elsif landed in (17,54,62,64,87,93,95,99) then landed:=case landed when 17 then 7 when 54 then 34 when 62 then 19 when 64 then 60 when 87 then 24 when 93 then 73 when 95 then 75 else 78 end; end if;
    state_json:=jsonb_set(state_json,array['positions',k],to_jsonb(landed),true); state_json:=jsonb_set(state_json,'{last_roll}',to_jsonb(roll_no),true);
    if landed=100 then state_json:=jsonb_set(state_json,'{winner}',to_jsonb(uid),true); gs.status:='round_complete'; update public.rooms set xp=xp+10,streak=case when last_played_on=current_date then streak when last_played_on=current_date-1 then streak+1 else 1 end,last_played_on=current_date,updated_at=now() where id=gs.room_id;
    elsif rawpos in (17,54,62,64,87,93,95,99) then
      state_json:=jsonb_set(state_json,'{punishment}',jsonb_build_object('id',extensions.gen_random_uuid(),'status','active','user_id',uid,'from',rawpos,'to',landed,'prompt','Kena ular! Ceritakan satu hal kecil yang kamu kangenin dari pasanganmu 💌'),true);
    else state_json:=jsonb_set(state_json,'{turn_seat}',to_jsonb(1-seat_no),true); end if;
  elsif p_action_type='punishment' and gs.game_type='snakes_ladders' then
    if char_length(trim(coalesce(p_payload->>'text',''))) not between 1 and 500 then raise exception 'Isi misi kecilnya dulu ya.'; end if;
    pun:=state_json->'punishment';
    if pun->>'status'<>'active' or pun->>'user_id'<>uid::text then raise exception 'Tantangan ini bukan giliranmu.'; end if;
    pun:=pun||jsonb_build_object('status','completed','response',trim(p_payload->>'text'),'completed_at',now());
    state_json:=jsonb_set(state_json,'{punishment}',pun,true); state_json:=jsonb_set(state_json,'{turn_seat}',to_jsonb(1-seat_no),true);
  else raise exception 'Aksi tidak cocok dengan mode game.';
  end if;
  gs.state:=state_json; gs.updated_at:=now(); update public.game_sessions set status=gs.status,round_no=gs.round_no,state=gs.state,updated_at=gs.updated_at where id=gs.id returning * into gs;
  update public.rooms set status=case when gs.status='round_complete' then 'ready' else 'playing' end,updated_at=now() where id=gs.room_id;
  return to_jsonb(gs);
end $$;

create or replace function public.close_ldr_game(p_session_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid;
begin
  update public.game_sessions s set status='finished',updated_at=now() where s.id=p_session_id and s.status in ('playing','round_complete') and exists(select 1 from public.room_members m where m.room_id=s.room_id and m.user_id=uid) returning room_id into rid;
  if rid is null then raise exception 'Sesi tidak ditemukan atau kamu bukan anggota room.' using errcode='42501'; end if;
  update public.rooms set status='ready',updated_at=now() where id=rid;
end $$;

create or replace function public.update_ldr_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid; out jsonb;
begin
  select room_id into rid from public.room_members where user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  if jsonb_typeof(p_settings->'async')<>'boolean' or jsonb_typeof(p_settings->'deep_enabled')<>'boolean' then raise exception 'Pengaturan tidak valid.'; end if;
  update public.rooms set settings=jsonb_set(jsonb_set(jsonb_set(jsonb_set(settings,'{async}',coalesce(p_settings->'async','false'::jsonb),true),'{deep_enabled}',coalesce(p_settings->'deep_enabled','true'::jsonb),true),'{meet_date}',coalesce(p_settings->'meet_date','null'::jsonb),true),'{ldr_since}',coalesce(p_settings->'ldr_since','null'::jsonb),true),updated_at=now() where id=rid returning settings into out;
  return out;
end $$;

create or replace function public.save_ldr_memory(p_body text)
returns public.room_memories language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid; item public.room_memories%rowtype;
begin
  select room_id into rid from public.room_members where user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  insert into public.room_memories(room_id,created_by,body) values(rid,uid,trim(p_body)) returning * into item; return item;
end $$;

create or replace function public.get_used_question_ids()
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid;
begin
  select room_id into rid from public.room_members where user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  return coalesce((select array_agg(question_id) from public.room_question_uses where room_id=rid),'{}'::text[]);
end $$;

create or replace function public.add_ldr_custom_question(p_question text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid; r public.rooms%rowtype; items jsonb; clean_question text;
begin
  clean_question:=trim(coalesce(p_question,''));
  if char_length(clean_question) not between 5 and 240 then raise exception 'Pertanyaan harus 5–240 karakter.'; end if;
  select room_id into rid from public.room_members where user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  select * into r from public.rooms where id=rid for update;
  items:=coalesce(r.settings->'custom_questions','[]'::jsonb);
  if jsonb_array_length(items)>=50 then raise exception 'Maksimal 50 pertanyaan buatan kalian.'; end if;
  if exists(select 1 from jsonb_array_elements_text(items) q where lower(q)=lower(clean_question)) then return items; end if;
  items:=items||jsonb_build_array(clean_question);
  update public.rooms set settings=jsonb_set(settings,'{custom_questions}',items,true),updated_at=now() where id=rid;
  return items;
end $$;

create or replace function public.get_ldr_game_history()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rid uuid;
begin
  select room_id into rid from public.room_members where user_id=uid;
  if rid is null then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'game_type',s.game_type,'status',s.status,'round_no',s.round_no,'state',s.state,'created_at',s.created_at) order by s.created_at desc)
    from (select * from public.game_sessions where room_id=rid and status in ('round_complete','finished') order by created_at desc limit 30) s),'[]'::jsonb);
end $$;

create or replace function public.notify_ldr_room(p_room_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.room_members where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Kamu bukan anggota room.' using errcode='42501'; end if;
  perform realtime.send(jsonb_build_object('at',extract(epoch from clock_timestamp())), 'room_changed', 'ldr-room:'||p_room_id::text, true);
end $$;

-- Authenticated database access is scoped by RLS; all inserts/mutations go through RPC.
revoke all on public.profiles,public.rooms,public.room_members,public.room_join_attempts,public.game_sessions,public.game_actions,public.room_memories,public.room_question_uses from anon,authenticated;
grant select on public.profiles,public.rooms,public.room_members,public.room_memories to authenticated;
grant insert on public.room_memories to authenticated;
grant update(display_name,avatar,updated_at) on public.profiles to authenticated;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('create_ldr_room','join_ldr_room','get_ldr_room','save_ldr_room','set_room_game_mode','start_snakes_ladders','roll_snakes_ladders','complete_snake_punishment','play_ttt_move','rematch_ttt','return_to_room','create_ldr_room_idempotent','join_ldr_room_idempotent','save_ldr_memory') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  end loop;
end $$;
revoke all on function public.touch_profile_from_auth() from public,anon,authenticated;
revoke all on function public.create_ldr_room(text,text,date),public.join_ldr_room(text,text,text),public.get_my_room(),public.start_ldr_game(text,text,jsonb,uuid,text),public.submit_ldr_action(uuid,uuid,text,jsonb),public.close_ldr_game(uuid),public.update_ldr_settings(jsonb),public.save_ldr_memory(text),public.get_used_question_ids(),public.add_ldr_custom_question(text),public.get_ldr_game_history(),public.notify_ldr_room(uuid) from public,anon;
grant execute on function public.create_ldr_room(text,text,date),public.join_ldr_room(text,text,text),public.get_my_room(),public.start_ldr_game(text,text,jsonb,uuid,text),public.submit_ldr_action(uuid,uuid,text,jsonb),public.close_ldr_game(uuid),public.update_ldr_settings(jsonb),public.save_ldr_memory(text),public.get_used_question_ids(),public.add_ldr_custom_question(text),public.get_ldr_game_history(),public.notify_ldr_room(uuid) to authenticated;

-- Broadcast/presence topics are private. Presence never grants membership.
drop policy if exists "LDR members may receive room realtime" on realtime.messages;
create policy "LDR members may receive room realtime" on realtime.messages for select to authenticated
  using (realtime.topic() like 'ldr-room:%' and exists (
    select 1 from public.room_members m where m.user_id=(select auth.uid()) and 'ldr-room:'||m.room_id::text=realtime.topic()
  ));
drop policy if exists "LDR members may send room realtime" on realtime.messages;
create policy "LDR members may send room realtime" on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'ldr-room:%' and exists (
    select 1 from public.room_members m where m.user_id=(select auth.uid()) and 'ldr-room:'||m.room_id::text=realtime.topic()
  ));
