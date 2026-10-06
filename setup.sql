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
    'roomStatus','waiting','gameSession','{}'::jsonb,
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
  updated := jsonb_set(updated,'{roomStatus}','"ready"'::jsonb,true);
  update ldr_rooms set token2=t,state=updated where code=r.code;
  return jsonb_build_object('code',r.code,'token',t,'slot',1,'state',updated);
end $$;

create or replace function public.get_ldr_room(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; slot_key text; other_key text; owner_slot integer;
  state_view jsonb; round_view jsonb; answers_view jsonb; guesses_view jsonb; game_type text; ready boolean;
begin
  select * into r from ldr_rooms where code=upper(trim(p_code));
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0;
  elsif p_token=r.token2 then player_slot:=1;
  else raise exception 'Sesi tidak cocok dengan room ini.'; end if;
  slot_key:=player_slot::text;other_key:=(1-player_slot)::text;state_view:=r.state;
  game_type:=coalesce(nullif(state_view->'gameSession'->>'gameType',''),state_view->>'mode','');
  round_view:=coalesce(state_view->'round','{}'::jsonb);answers_view:=coalesce(round_view->'answers','{}'::jsonb);
  if game_type='guess' then
    owner_slot:=coalesce((round_view->>'owner')::integer,0);
    guesses_view:=coalesce(round_view->'guesses','{}'::jsonb);
    ready:=(answers_view ? owner_slot::text) and (guesses_view ? (1-owner_slot)::text);
    if ready then
      round_view:=jsonb_set(round_view,'{revealed}','true'::jsonb,true);
    else
      if answers_view ? owner_slot::text then round_view:=jsonb_set(round_view,'{secretReady}','true'::jsonb,true);end if;
      if player_slot<>owner_slot then answers_view:=answers_view-owner_slot::text;
      else guesses_view:=guesses_view-(1-owner_slot)::text;end if;
      round_view:=jsonb_set(round_view,'{answers}',answers_view,true);
      round_view:=jsonb_set(round_view,'{guesses}',guesses_view,true);
    end if;
  elsif game_type in ('wyr','quiz') and not (answers_view ? '0' and answers_view ? '1') then
    round_view:=jsonb_set(round_view,'{answers}',answers_view-other_key,true);
  end if;
  state_view:=jsonb_set(state_view,'{round}',round_view,true);
  return jsonb_build_object('code',r.code,'slot',player_slot,'state',state_view);
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
  -- Game selection/session hanya berubah lewat RPC ber-lock, bukan save dari client.
  if r.state ? 'mode' then safe_state:=jsonb_set(safe_state,'{mode}',r.state->'mode',true); end if;
  if r.state ? 'gameSession' then safe_state:=jsonb_set(safe_state,'{gameSession}',r.state->'gameSession',true); end if;
  -- Papan TTT dan skor global juga hanya diubah melalui RPC validasi giliran.
  if r.state ? 'ttt' then safe_state:=jsonb_set(safe_state,'{ttt}',r.state->'ttt',true); else safe_state:=safe_state-'ttt'; end if;
  if r.state ? 'scores' then safe_state:=jsonb_set(safe_state,'{scores}',r.state->'scores',true); else safe_state:=safe_state-'scores'; end if;

  -- Round hanya digabung jika ID ronde sama; ronde baru boleh mengganti jawaban lama.
  old_round:=coalesce(r.state->'round','{}'::jsonb);
  new_round:=coalesce(p_state->'round','{}'::jsonb);
  if p_state->'gameSession'->>'id' is distinct from r.state->'gameSession'->>'id' then
    new_round:=old_round; -- klien dari sesi lama tidak boleh mengembalikan kartu lama.
  elsif old_round->>'id' is not null and old_round->>'id'=new_round->>'id' then
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

  -- Snake state changes only through its validated RPCs, never through generic save.
  safe_state:=safe_state-'snakeGame';
  if r.state ? 'snakeGame' then safe_state:=jsonb_set(safe_state,'{snakeGame}',r.state->'snakeGame',true); end if;
  if r.state->'snakeGame'->>'status'='playing' then
    safe_state:=jsonb_set(safe_state,'{gameSession}',r.state->'gameSession',true);
    safe_state:=jsonb_set(safe_state,'{mode}','"snakes"'::jsonb,true);
  end if;

  update ldr_rooms set state=safe_state where code=r.code;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.set_room_game_mode(p_code text,p_token uuid,p_game_type text,p_session_id text,p_round jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; safe_round jsonb;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0;elsif p_token=r.token2 then player_slot:=1;else raise exception 'Sesi tidak cocok dengan room ini.';end if;
  if jsonb_array_length(coalesce(r.state->'players','[]'::jsonb))<>2 then raise exception 'Room perlu dua pemain sebelum mulai.';end if;
  if p_game_type not in ('guess','wyr','deep','hot','challenge','quiz','date','story','draw','ttt','daily') then raise exception 'Tipe game tidak terdaftar.';end if;
  if length(coalesce(p_session_id,''))<8 or length(p_session_id)>80 then raise exception 'ID sesi tidak valid.';end if;
  if r.state->'snakeGame'->>'status'='playing' then raise exception 'Selesaikan Ular Tangga sebelum mengganti game.';end if;
  safe_round:=coalesce(p_round,'{}'::jsonb);
  if p_game_type in ('deep','guess','daily') then
    if length(trim(coalesce(safe_round->>'q','')))<1 or coalesce(safe_round->>'questionId','') not like p_game_type||'-%' then raise exception 'Kartu pertanyaan tidak cocok dengan game.';end if;
  elsif p_game_type='wyr' then
    if coalesce((safe_round->>'index')::integer,-1)<0 or coalesce((safe_round->>'index')::integer,-1)>5 then raise exception 'Pilihan Would You Rather tidak valid.';end if;
  elsif p_game_type='hot' then
    if safe_round->>'q' not in ('Bubur diaduk atau nggak diaduk?','Nanas di pizza: masuk akal atau kriminal?','Mie kuah pakai nasi: iya atau tidak?','Tidur pakai kaus kaki: nyaman atau aneh?','Pancake lebih enak daripada waffle?','Sereal dulu atau susu dulu?','Film bagus boleh ditonton sambil scroll HP?','Mandi pagi atau mandi malam?') then raise exception 'Topik Hot Takes tidak valid.';end if;
  elsif p_game_type='challenge' then
    if safe_round->>'q' not in ('Kirim foto langit yang kamu lihat hari ini ☁️','Bikin pantun 2 baris buat pasanganmu ✍️','Kirim selfie dengan ekspresi paling absurd 🤪','Nyanyikan 10 detik lagu pilihan pasanganmu 🎤','Gambar pasanganmu pakai tangan non-dominan 🎨','Pilih menu sama, masak atau pesan, lalu bandingkan 🍜','Rekam voice note bilang satu hal kecil yang kamu syukuri 💌','Kirim emoji paling aneh yang bisa kamu temukan 👾') then raise exception 'Tantangan LDR tidak valid.';end if;
  end if;
  safe_round:=jsonb_set(safe_round,'{id}',to_jsonb(p_session_id),true);
  safe_round:=jsonb_set(safe_round,'{answers}',coalesce(safe_round->'answers','{}'::jsonb),true);
  r.state:=jsonb_set(r.state,'{mode}',to_jsonb(p_game_type),true);
  r.state:=jsonb_set(r.state,'{round}',safe_round,true);
  r.state:=jsonb_set(r.state,'{gameSession}',jsonb_build_object('id',p_session_id,'gameType',p_game_type,'status','playing','turnSlot',player_slot,'round',1,'updatedAt',clock_timestamp()),true);
  if p_game_type='ttt' and r.state->'ttt' is null then
    r.state:=jsonb_set(r.state,'{ttt}',jsonb_build_object('board',jsonb_build_array('','','','','','','','',''),'turnSlot',player_slot,'wins',jsonb_build_object('0',0,'1',0),'draws',0,'round',1,'winner',null,'lastActionId',null),true);
  end if;
  r.state:=jsonb_set(r.state,'{roomStatus}','"playing"'::jsonb,true);
  update public.ldr_rooms set state=r.state where code=r.code;
  return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;

-- Ular Tangga: semua lemparan, giliran, posisi, dan hukuman diputuskan di database.
create or replace function public.start_snakes_ladders(p_code text,p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; g jsonb;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0; elsif p_token=r.token2 then player_slot:=1;
  else raise exception 'Sesi tidak cocok dengan room ini.'; end if;
  if jsonb_array_length(coalesce(r.state->'players','[]'::jsonb))<>2 then raise exception 'Room perlu dua pemain sebelum mulai.'; end if;
  if coalesce(r.state->'snakeGame'->>'status','finished') not in ('finished','cancelled') then raise exception 'Game Ular Tangga sedang berjalan.'; end if;
  g:=jsonb_build_object(
    'id',gen_random_uuid()::text,'gameType','snakes','status','playing',
    'positions',jsonb_build_object('0',1,'1',1),'turnSlot',0,'diceValue',null,
    'round',1,'winner',null,'punishment',null,'lastActionId',null,'lastRollAt',null,
    'lastEvent',jsonb_build_object('type','start','text','Papan siap! Giliran pertama dimulai 🐍'),
    'stats',jsonb_build_object('0',jsonb_build_object('rolls',0,'snakes',0,'ladders',0,'questions',0,'challenges',0,'xp',0),'1',jsonb_build_object('rolls',0,'snakes',0,'ladders',0,'questions',0,'challenges',0,'xp',0)),
    'updatedAt',clock_timestamp()
  );
  r.state:=jsonb_set(r.state,'{snakeGame}',g,true);
  r.state:=jsonb_set(r.state,'{mode}','"snakes"'::jsonb,true);
  r.state:=jsonb_set(r.state,'{gameSession}',jsonb_build_object('id',g->>'id','gameType','snakes','status','playing','turnSlot',0,'round',1,'updatedAt',clock_timestamp()),true);
  r.state:=jsonb_set(r.state,'{roomStatus}','"playing"'::jsonb,true);
  update public.ldr_rooms set state=r.state where code=r.code;
  return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;

create or replace function public.roll_snakes_ladders(p_code text,p_token uuid,p_action_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; slot_key text; g jsonb; positions jsonb; stats jsonb; mine jsonb;
  from_pos integer; dice integer; landed integer; to_pos integer; raw_pos integer; next_turn integer;
  tile text:='normal'; event_text text; xp_bonus integer:=0; gift integer:=0;
  punishment jsonb:=null; questions text[]:=array['Apa hal kecil dari pasanganmu yang paling kamu suka?','Kapan terakhir kali pasanganmu membuat kamu tersenyum?','Apa satu tempat yang ingin kamu kunjungi bersama?','Sebutkan satu kenangan sederhana yang pengin kamu ulang.','Hal apa yang bikin kamu merasa didukung pasangan?'];
  challenges text[]:=array['Kirim satu pujian tulus ke pasanganmu.','Ceritakan satu memori lucu kalian.','Buat julukan lucu untuk pasanganmu.','Sebutkan tiga hal yang kamu sukai dari pasanganmu.','Kirim emoji pilihan pasangan dan pakai sampai giliran berikutnya.'];
  ladders jsonb:='{"4":14,"9":31,"20":38,"28":84,"40":59,"63":81,"71":91}'::jsonb;
  snakes jsonb:='{"17":7,"54":34,"62":19,"64":60,"87":24,"93":73,"95":75,"99":78}'::jsonb;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0; elsif p_token=r.token2 then player_slot:=1;
  else raise exception 'Sesi tidak cocok dengan room ini.'; end if;
  slot_key:=player_slot::text;g:=r.state->'snakeGame';
  if g is null or g->>'gameType'<>'snakes' then raise exception 'Sesi Ular Tangga belum dimulai.'; end if;
  if g->>'lastActionId'=p_action_id::text then return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state); end if;
  if g->>'status'<>'playing' then raise exception 'Game sudah selesai.'; end if;
  if coalesce((g->>'turnSlot')::integer,-1)<>player_slot then raise exception 'Belum giliranmu.'; end if;
  if coalesce(g->'punishment'->>'status','')='active' then raise exception 'Selesaikan hukuman dulu.'; end if;
  if g->>'lastRollAt' is not null and clock_timestamp()-(g->>'lastRollAt')::timestamptz<interval '500 milliseconds' then raise exception 'Tunggu sebentar sebelum lempar lagi.'; end if;
  positions:=g->'positions';stats:=g->'stats';mine:=coalesce(stats->slot_key,'{}'::jsonb);
  from_pos:=coalesce((positions->>slot_key)::integer,1);dice:=1+floor(random()*6)::integer;raw_pos:=from_pos+dice;landed:=from_pos;to_pos:=from_pos;
  if raw_pos<=100 then
    landed:=raw_pos;to_pos:=raw_pos;
    if snakes ? raw_pos::text then to_pos:=(snakes->>raw_pos::text)::integer;tile:='snake';
    elsif ladders ? raw_pos::text then to_pos:=(ladders->>raw_pos::text)::integer;tile:='ladder';end if;
  else tile:='overshoot';end if;
  positions:=jsonb_set(positions,array[slot_key],to_jsonb(to_pos),true);
  mine:=jsonb_set(mine,'{rolls}',to_jsonb(coalesce((mine->>'rolls')::integer,0)+1),true);
  if tile='snake' then
    mine:=jsonb_set(mine,'{snakes}',to_jsonb(coalesce((mine->>'snakes')::integer,0)+1),true);
    if random()<0.5 then punishment:=jsonb_build_object('id',gen_random_uuid()::text,'status','active','type','question','playerSlot',player_slot,'from',landed,'to',to_pos,'prompt',questions[1+floor(random()*array_length(questions,1))::integer]);mine:=jsonb_set(mine,'{questions}',to_jsonb(coalesce((mine->>'questions')::integer,0)+1),true);
    else punishment:=jsonb_build_object('id',gen_random_uuid()::text,'status','active','type','challenge','playerSlot',player_slot,'from',landed,'to',to_pos,'prompt',challenges[1+floor(random()*array_length(challenges,1))::integer]);mine:=jsonb_set(mine,'{challenges}',to_jsonb(coalesce((mine->>'challenges')::integer,0)+1),true);end if;
    event_text:='🐍 Kena ular! Turun '||landed||' → '||to_pos||' · jalani hukuman dulu.';
  elsif tile='ladder' then mine:=jsonb_set(mine,'{ladders}',to_jsonb(coalesce((mine->>'ladders')::integer,0)+1),true);event_text:='🪜 Naik tangga! '||landed||' → '||to_pos;
  elsif tile='overshoot' then event_text:='Belum pas! Dadu '||dice||', pion tetap di '||from_pos||'. Harus tepat ke 100.';
  else event_text:='Dadu '||dice||' · maju ke '||to_pos;end if;

  if tile not in ('snake','ladder','overshoot') then
    if to_pos=any(array[5,26,50,77]) then tile:='heart';xp_bonus:=5;event_text:=event_text||' · 💗 bonus +5 XP';
    elsif to_pos=any(array[15,43,66,90]) then tile:='gift';gift:=floor(random()*3)::integer;
      if gift=0 then xp_bonus:=10;event_text:=event_text||' · 🎁 hadiah +10 XP';
      elsif gift=1 then to_pos:=least(100,to_pos+2);positions:=jsonb_set(positions,array[slot_key],to_jsonb(to_pos),true);event_text:=event_text||' · 🎁 maju 2 kotak';
      else event_text:=event_text||' · 🎁 bonus satu lemparan lagi';end if;
    elsif to_pos=any(array[23,56,82]) then tile:='question';event_text:=event_text||' · 💬 pertanyaan: '||questions[1+floor(random()*array_length(questions,1))::integer];mine:=jsonb_set(mine,'{questions}',to_jsonb(coalesce((mine->>'questions')::integer,0)+1),true);
    elsif to_pos=any(array[33,68,88]) then tile:='challenge';event_text:=event_text||' · 🔥 tantangan: '||challenges[1+floor(random()*array_length(challenges,1))::integer];mine:=jsonb_set(mine,'{challenges}',to_jsonb(coalesce((mine->>'challenges')::integer,0)+1),true);end if;
  end if;
  if xp_bonus>0 then mine:=jsonb_set(mine,'{xp}',to_jsonb(coalesce((mine->>'xp')::integer,0)+xp_bonus),true);r.state:=jsonb_set(r.state,'{xp}',to_jsonb(coalesce((r.state->>'xp')::integer,0)+xp_bonus),true);end if;
  stats:=jsonb_set(stats,array[slot_key],mine,true);next_turn:=case when punishment is not null or gift=2 then player_slot else 1-player_slot end;
  g:=jsonb_set(g,'{positions}',positions,true);g:=jsonb_set(g,'{stats}',stats,true);g:=jsonb_set(g,'{turnSlot}',to_jsonb(next_turn),true);
  g:=jsonb_set(g,'{diceValue}',to_jsonb(dice),true);g:=jsonb_set(g,'{round}',to_jsonb(coalesce((g->>'round')::integer,0)+1),true);
  g:=jsonb_set(g,'{punishment}',coalesce(punishment,'null'::jsonb),true);g:=jsonb_set(g,'{lastActionId}',to_jsonb(p_action_id::text),true);g:=jsonb_set(g,'{lastRollAt}',to_jsonb(clock_timestamp()),true);
  g:=jsonb_set(g,'{lastEvent}',jsonb_build_object('type',tile,'from',from_pos,'roll',dice,'landed',landed,'to',to_pos,'text',event_text),true);g:=jsonb_set(g,'{updatedAt}',to_jsonb(clock_timestamp()),true);
  if to_pos=100 then g:=jsonb_set(g,'{status}','"finished"'::jsonb,true);g:=jsonb_set(g,'{winner}',to_jsonb(player_slot),true);event_text:=event_text||' · 🏆 menang!';g:=jsonb_set(g,'{lastEvent,text}',to_jsonb(event_text),true);r.state:=jsonb_set(r.state,'{gameSession,status}','"finished"'::jsonb,true);
  else g:=jsonb_set(g,'{status}','"playing"'::jsonb,true);end if;
  r.state:=jsonb_set(r.state,'{snakeGame}',g,true);r.state:=jsonb_set(r.state,'{mode}','"snakes"'::jsonb,true);r.state:=jsonb_set(r.state,'{roomStatus}','"playing"'::jsonb,true);
  update public.ldr_rooms set state=r.state where code=r.code;return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;

create or replace function public.complete_snake_punishment(p_code text,p_token uuid,p_punishment_id text,p_response text,p_action_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; slot_key text; g jsonb; pun jsonb; stats jsonb; mine jsonb; response text;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.'; end if;
  if p_token=r.token1 then player_slot:=0;elsif p_token=r.token2 then player_slot:=1;else raise exception 'Sesi tidak cocok dengan room ini.';end if;
  slot_key:=player_slot::text;g:=r.state->'snakeGame';pun:=g->'punishment';
  if g->>'lastActionId'=p_action_id::text then return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);end if;
  if pun->>'status'<>'active' or pun->>'id'<>p_punishment_id then raise exception 'Hukuman sudah selesai atau tidak cocok.';end if;
  if coalesce((pun->>'playerSlot')::integer,-1)<>player_slot then raise exception 'Hukuman ini milik pasanganmu.';end if;
  response:=left(trim(coalesce(p_response,'')),300);if length(response)<1 then raise exception 'Isi jawaban singkat dulu ya.';end if;
  pun:=pun||jsonb_build_object('status','completed','response',response,'completedAt',clock_timestamp());g:=jsonb_set(g,'{punishment}',pun,true);
  g:=jsonb_set(g,'{turnSlot}',to_jsonb(1-player_slot),true);g:=jsonb_set(g,'{lastActionId}',to_jsonb(p_action_id::text),true);g:=jsonb_set(g,'{updatedAt}',to_jsonb(clock_timestamp()),true);
  g:=jsonb_set(g,'{lastEvent}',jsonb_build_object('type','punishment','text','Hukuman selesai. Giliran lanjut ke pasangan 💌'),true);
  stats:=g->'stats';mine:=coalesce(stats->slot_key,'{}'::jsonb);mine:=jsonb_set(mine,'{punishmentsCompleted}',to_jsonb(coalesce((mine->>'punishmentsCompleted')::integer,0)+1),true);g:=jsonb_set(g,'{stats}',jsonb_set(stats,array[slot_key],mine,true),true);
  r.state:=jsonb_set(r.state,'{snakeGame}',g,true);update public.ldr_rooms set state=r.state where code=r.code;
  return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;

create or replace function public.play_ttt_move(p_code text,p_token uuid,p_cell integer,p_action_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; mark text; t jsonb; board jsonb; wins jsonb;
  has_won boolean:=false; is_draw boolean:=false; total_xp integer:=0; score_state jsonb;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.';end if;
  if p_token=r.token1 then player_slot:=0;elsif p_token=r.token2 then player_slot:=1;else raise exception 'Sesi tidak cocok dengan room ini.';end if;
  t:=r.state->'ttt';if t is null or jsonb_array_length(coalesce(t->'board','[]'::jsonb))<>9 then raise exception 'Papan Tic-Tac-Toe belum disiapkan.';end if;
  if t->>'lastActionId'=p_action_id::text then return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);end if;
  if (t->>'winner') is not null and t->>'winner'<>'null' then raise exception 'Ronde sudah selesai.';end if;
  if p_cell<0 or p_cell>8 then raise exception 'Kotak tidak valid.';end if;
  if coalesce((t->>'turnSlot')::integer,-1)<>player_slot then raise exception 'Belum giliranmu.';end if;
  board:=t->'board';if coalesce(board->>p_cell,'')<>'' then raise exception 'Kotak itu sudah terisi.';end if;
  mark:='slot:'||player_slot::text;board:=jsonb_set(board,array[p_cell::text],to_jsonb(mark),false);
  select exists(select 1 from (values (0,1,2),(3,4,5),(6,7,8),(0,3,6),(1,4,7),(2,5,8),(0,4,8),(2,4,6)) as line(a,b,c)
    where board->>a=mark and board->>b=mark and board->>c=mark) into has_won;
  select not exists(select 1 from generate_series(0,8) as series(cell) where coalesce(board->>cell,'')='') into is_draw;
  t:=jsonb_set(t,'{board}',board,true);t:=jsonb_set(t,'{turnSlot}',to_jsonb(1-player_slot),true);t:=jsonb_set(t,'{lastActionId}',to_jsonb(p_action_id::text),true);
  if has_won then
    t:=jsonb_set(t,'{winner}',to_jsonb(mark),true);wins:=t->'wins';wins:=jsonb_set(wins,array[player_slot::text],to_jsonb(coalesce((wins->>player_slot::text)::integer,0)+1),true);t:=jsonb_set(t,'{wins}',wins,true);
    score_state:=coalesce(r.state->'scores',jsonb_build_object('0',0,'1',0,'draws',0));score_state:=jsonb_set(score_state,array[player_slot::text],to_jsonb(coalesce((score_state->>player_slot::text)::integer,0)+1),true);r.state:=jsonb_set(r.state,'{scores}',score_state,true);
    total_xp:=coalesce((r.state->>'xp')::integer,0)+10;r.state:=jsonb_set(r.state,'{xp}',to_jsonb(total_xp),true);
  elsif is_draw then t:=jsonb_set(t,'{winner}','"draw"'::jsonb,true);t:=jsonb_set(t,'{draws}',to_jsonb(coalesce((t->>'draws')::integer,0)+1),true);end if;
  r.state:=jsonb_set(r.state,'{ttt}',t,true);if has_won or is_draw then r.state:=jsonb_set(r.state,'{gameSession,status}',case when has_won or is_draw then '"round_complete"'::jsonb else '"playing"'::jsonb end,true);end if;
  update public.ldr_rooms set state=r.state where code=r.code;return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;

create or replace function public.rematch_ttt(p_code text,p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer; t jsonb; next_turn integer;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.';end if;
  if p_token=r.token1 then player_slot:=0;elsif p_token=r.token2 then player_slot:=1;else raise exception 'Sesi tidak cocok dengan room ini.';end if;
  t:=r.state->'ttt';if t is null or (t->>'winner') is null or t->>'winner'='null' then raise exception 'Ronde ini belum selesai.';end if;
  next_turn:=coalesce((t->>'turnSlot')::integer,1-player_slot);
  t:=jsonb_set(t,'{board}',jsonb_build_array('','','','','','','','',''),true);t:=jsonb_set(t,'{winner}','null'::jsonb,true);t:=jsonb_set(t,'{turnSlot}',to_jsonb(next_turn),true);t:=jsonb_set(t,'{round}',to_jsonb(coalesce((t->>'round')::integer,0)+1),true);t:=jsonb_set(t,'{lastActionId}','null'::jsonb,true);
  r.state:=jsonb_set(r.state,'{ttt}',t,true);r.state:=jsonb_set(r.state,'{gameSession,status}','"playing"'::jsonb,true);
  update public.ldr_rooms set state=r.state where code=r.code;return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;


create or replace function public.return_to_room(p_code text,p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r ldr_rooms%rowtype; player_slot integer;
begin
  select * into r from public.ldr_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room tidak ditemukan.';end if;
  if p_token=r.token1 then player_slot:=0;elsif p_token=r.token2 then player_slot:=1;else raise exception 'Sesi tidak cocok dengan room ini.';end if;
  if r.state->'snakeGame'->>'status'='playing' then raise exception 'Selesaikan game yang sedang berjalan dulu.';end if;
  r.state:=jsonb_set(r.state,'{mode}','""'::jsonb,true);
  r.state:=jsonb_set(r.state,'{gameSession,status}','"finished"'::jsonb,true);
  r.state:=jsonb_set(r.state,'{gameSession,gameType}','""'::jsonb,true);
  r.state:=jsonb_set(r.state,'{roomStatus}','"ready"'::jsonb,true);
  update public.ldr_rooms set state=r.state where code=r.code;
  return jsonb_build_object('ok',true,'slot',player_slot,'state',r.state);
end $$;
revoke all on function public.create_ldr_room(text,text) from public;
revoke all on function public.join_ldr_room(text,text,text) from public;
revoke all on function public.get_ldr_room(text,uuid) from public;
revoke all on function public.save_ldr_room(text,uuid,jsonb) from public;
revoke all on function public.set_room_game_mode(text,uuid,text,text,jsonb) from public;
revoke all on function public.ldr_jsonb_deep_merge(jsonb,jsonb) from public;
revoke all on function public.start_snakes_ladders(text,uuid) from public;
revoke all on function public.roll_snakes_ladders(text,uuid,uuid) from public;
revoke all on function public.complete_snake_punishment(text,uuid,text,text,uuid) from public;
revoke all on function public.play_ttt_move(text,uuid,integer,uuid) from public;
revoke all on function public.rematch_ttt(text,uuid) from public;
revoke all on function public.return_to_room(text,uuid) from public;
grant execute on function public.create_ldr_room(text,text) to anon, authenticated;
grant execute on function public.join_ldr_room(text,text,text) to anon, authenticated;
grant execute on function public.get_ldr_room(text,uuid) to anon, authenticated;
grant execute on function public.save_ldr_room(text,uuid,jsonb) to anon, authenticated;
grant execute on function public.set_room_game_mode(text,uuid,text,text,jsonb) to anon, authenticated;
grant execute on function public.start_snakes_ladders(text,uuid) to anon, authenticated;
grant execute on function public.roll_snakes_ladders(text,uuid,uuid) to anon, authenticated;
grant execute on function public.complete_snake_punishment(text,uuid,text,text,uuid) to anon, authenticated;
grant execute on function public.play_ttt_move(text,uuid,integer,uuid) to anon, authenticated;
grant execute on function public.rematch_ttt(text,uuid) to anon, authenticated;
grant execute on function public.return_to_room(text,uuid) to anon, authenticated;
