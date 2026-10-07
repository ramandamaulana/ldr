import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useAuthSession } from '../features/auth/useAuthSession';
import { useRoomData } from '../features/room/useRoomData';
import { messageOf } from '../lib/errors';
import type { GameType, RoomSnapshot } from '../types/room';
import { AVATARS, CHALLENGES, GAMES, HOT_TAKES, LEVELS, MINI_EVENTS, WYR, CATEGORIES, choosePrompt, questionRows } from '../features/games/registry';
import { SnakesBoard, TicTacToe } from '../features/games/BoardGames';

export function App() {
  const { client,user,ready:authReady,error:configError,setError } = useAuthSession();
  const queryClient=useQueryClient();
  const [name,setName]=useState(()=>localStorage.getItem('ldr_name')||'');
  const [avatar,setAvatar]=useState<string>(()=>localStorage.getItem('ldr_avatar')||AVATARS[0]);
  const [roomCode,setRoomCode]=useState('');
  const [category,setCategory]=useState('Semua kategori');
  const [depth,setDepth]=useState(1);
  const [filterDeep,setFilterDeep]=useState(true);
  const [text,setText]=useState('');
  const [choice,setChoice]=useState<number|null>(null);
  const [status,setStatus]=useState<'connecting'|'connected'|'reconnecting'|'offline'>('connecting');
  const [dark,setDark]=useState(()=>localStorage.getItem('ldr_dark')==='true');
  const [toast,setToast]=useState('');
  const [meetDate,setMeetDate]=useState('');
  const [ldrSince,setLdrSince]=useState('');
  const [customQuestion,setCustomQuestion]=useState('');

  const notify=useCallback((message:string)=>{setToast(message);window.setTimeout(()=>setToast(''),2600)},[]);
  useEffect(()=>{document.documentElement.dataset.theme=dark?'dark':'light';localStorage.setItem('ldr_dark',String(dark))},[dark]);
  useEffect(()=>{if(name)localStorage.setItem('ldr_name',name)},[name]);
  useEffect(()=>{localStorage.setItem('ldr_avatar',avatar)},[avatar]);

  const {roomQuery,room,memoriesQuery,historyQuery,usedQuery,online}=useRoomData(client,user,status,setStatus);
  useEffect(()=>{
    const settings=room?.room.settings;
    if(!settings)return;
    setMeetDate(typeof settings.meet_date==='string'?settings.meet_date:'');
    setLdrSince(typeof settings.ldr_since==='string'?settings.ldr_since:'');
    setFilterDeep(settings.deep_enabled!==false);
  },[room?.room.id,room?.room.updated_at]);
  const refresh=useCallback(async()=>{await queryClient.invalidateQueries({queryKey:['my-room',user?.id]});if(room)await queryClient.invalidateQueries({queryKey:['game-history',room.room.id]})},[queryClient,user?.id,room?.room.id]);
  const runRpc=useCallback(async<T,>(name:string,args:Record<string,unknown>):Promise<T>=>{
    if(!client)throw new Error('Supabase belum tersambung.');
    const {data,error}=await client.rpc(name,args as never);if(error)throw error;return data as T;
  },[client]);
  const announce=useCallback(async()=>{if(!room)return;const {error}=await client!.rpc('notify_ldr_room',{p_room_id:room.room.id});if(error)console.warn('[REALTIME] Notifikasi belum terkirim:',error.message)},[client,room]);

  const accountMutation=useMutation({mutationFn:async(kind:'guest'|'google')=>{
    if(!client)throw new Error(configError||'Supabase belum siap.');
    if(kind==='guest'){const {error}=await client.auth.signInAnonymously({options:{data:{display_name:name.trim()||'Teman'}}});if(error)throw error;return}
    if(user?.is_anonymous){const {error}=await client.auth.linkIdentity({provider:'google',options:{redirectTo:window.location.origin}});if(error)throw error;return}
    const {error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:window.location.origin,queryParams:{access_type:'offline',prompt:'consent'}}});if(error)throw error;
  },onError:(e)=>setError(messageOf(e))});
  const roomMutation=useMutation({mutationFn:async(action:'create'|'join')=>{
    if(!client)throw new Error('Supabase belum siap.');
    if(name.trim().length<1)throw new Error('Isi nama panggilan dulu ya 🙂');
    if(!user)throw new Error('Sesi login sedang dimuat. Coba sebentar lagi.');
    const {data,error}=action==='create'
      ?await client.rpc('create_ldr_room',{p_display_name:name.trim(),p_avatar:avatar,p_ldr_since:ldrSince||null})
      :await client.rpc('join_ldr_room',{p_code:roomCode.trim().toUpperCase(),p_display_name:name.trim(),p_avatar:avatar});
    if(error)throw error;const result=data as {room_id?:string;code?:string;error_code?:string};
    if(result?.error_code==='join_rate_limited')throw new Error('Terlalu banyak percobaan kode. Coba lagi sekitar 15 menit ya.');
    if(result?.error_code==='room_not_found')throw new Error('Kode room tidak ditemukan atau room sudah ditutup.');
    if(result?.error_code==='room_full')throw new Error('Room ini sudah penuh. Isinya memang cuma berdua 💗');
    if(!result?.room_id||!result.code)throw new Error('Server belum mengirim kode room yang valid.');
    setRoomCode(result.code);await refresh();return result;
  },onSuccess:async(result)=>{notify(`Room ${result.code} siap! Kode cuma untuk kalian berdua 💗`);await announce()},onError:(e)=>notify(messageOf(e))});

  const startMutation=useMutation({mutationFn:async({game,dailyPrompt,dailyId}:{game:GameType;dailyPrompt?:string;dailyId?:string})=>{
    if(!room)throw new Error('Room belum tersambung.');
    if(room.members.length<2)throw new Error('Tunggu pasanganmu masuk dulu ya 💗');
    let usedIds=usedQuery.data;
    if(!usedIds){const refreshed=await usedQuery.refetch();usedIds=refreshed.data||[]}
    const picked=dailyPrompt&&(!dailyId||!(usedIds||[]).includes(dailyId))?{id:dailyId,prompt:dailyPrompt,options:[] as string[]}:dailyPrompt?{...choosePrompt(game,category,filterDeep?depth:2,usedIds||[]),options:[] as string[]}:game==='would_you_rather'?{id:`wyr-${Date.now()}`,prompt:'Pilih yang paling kamu rela jalani 😄',options:WYR[Math.floor(Math.random()*WYR.length)]!}
      :game==='hot_takes'?{id:`hot-${Date.now()}`,prompt:HOT_TAKES[Math.floor(Math.random()*HOT_TAKES.length)]!,options:['Setuju','Netral','Tidak setuju']}
      :game==='ldr_challenge'?{id:`challenge-${Date.now()}`,prompt:CHALLENGES[Math.floor(Math.random()*CHALLENGES.length)]!,options:[] as string[]}
      :game==='couple_quiz'&&Array.isArray(room.room.settings.custom_questions)&&room.room.settings.custom_questions.length>0?(()=>{const custom=room.room.settings.custom_questions as string[];const options=custom.map((prompt,index)=>({id:`custom-${index}`,prompt,category:'💞 Buatan kita',difficulty:1})).filter((item)=>!(usedIds||[]).includes(item.id));return{...(options[Math.floor(Math.random()*options.length)]||choosePrompt(game,category,filterDeep?depth:2,usedIds||[])),options:[] as string[]}})()
      :['deep_talk','guess_me','couple_quiz'].includes(game)?{...choosePrompt(game,category,filterDeep?depth:2,usedIds||[]),options:[] as string[]}
      :{id:undefined,prompt:game==='dream_date'?'Kalau kita punya satu hari kencan impian, mulainya dari mana?':game==='story_chain'?'Pada suatu hari, paket misterius tiba di depan pintu…':'',options:[] as string[]};
    const session=await runRpc<RoomSnapshot['game']>('start_ldr_game',{p_game_type:game,p_prompt:picked.prompt,p_options:picked.options,p_action_id:crypto.randomUUID(),p_question_id:picked.id||null});
    if(!session)throw new Error('Sesi game belum dibuat.');return session;
  },onSuccess:async()=>{setText('');setChoice(null);await refresh();await announce()},onError:(e)=>notify(messageOf(e))});
  const actionMutation=useMutation({mutationFn:async({action,payload,idempotencyKey}:{action:string;payload:Record<string,unknown>;idempotencyKey:string;signature:string})=>{
    if(!room?.game)throw new Error('Sesi game tidak ditemukan.');
    const result=await runRpc('submit_ldr_action',{p_session_id:room.game.id,p_idempotency_key:idempotencyKey,p_action_type:action,p_payload:payload});return result;
  },onSuccess:async(...result)=>{const variables=result[1] as {signature:string};pendingActionIds.current.delete(variables.signature);setText('');setChoice(null);await refresh();await announce()},onError:(e)=>{notify(messageOf(e));void refresh()}});
  const pendingActionIds=useRef(new Map<string,string>());
  const switchingGame=useRef(false);
  const sendAction=(action:string,payload:Record<string,unknown>)=>{const signature=JSON.stringify([room?.game?.id,action,payload]);let idempotencyKey=pendingActionIds.current.get(signature);if(!idempotencyKey){idempotencyKey=crypto.randomUUID();pendingActionIds.current.set(signature,idempotencyKey)}actionMutation.mutate({action,payload,idempotencyKey,signature})};
  const closeMutation=useMutation({mutationFn:async()=>{
    if(!room?.game) return;const {error}=await client!.rpc('close_ldr_game',{p_session_id:room.game.id});if(error)throw error;
  },onSuccess:async()=>{await refresh();await announce()},onError:(e)=>notify(messageOf(e))});
  const settingsMutation=useMutation({mutationFn:async()=>{
    const {error}=await client!.rpc('update_ldr_settings',{p_settings:{async:room?.room.settings.async===true,deep_enabled:filterDeep,meet_date:meetDate||null,ldr_since:ldrSince||null}});if(error)throw error;
  },onSuccess:async()=>{notify('Pengaturan kalian sudah disimpan ✨');await refresh();await announce()},onError:(e)=>notify(messageOf(e))});
  const memoryMutation=useMutation({mutationFn:async(body:string)=>{const {error}=await client!.rpc('save_ldr_memory',{p_body:body});if(error)throw error},onSuccess:async()=>{notify('Masuk ke Memory Jar 🫙');await queryClient.invalidateQueries({queryKey:['memories',room?.room.id]});await announce()},onError:(e)=>notify(messageOf(e))});
  const customQuestionMutation=useMutation({mutationFn:async(question:string)=>{const {error}=await client!.rpc('add_ldr_custom_question',{p_question:question});if(error)throw error},onSuccess:async()=>{setCustomQuestion('');notify('Pertanyaan kalian sudah ditambahkan 🧠');await refresh();await announce()},onError:(e)=>notify(messageOf(e))});

  const signOut=async()=>{if(!client)return;const {error}=await client.auth.signOut();if(error)notify(error.message);else{queryClient.clear();notify('Sesi sudah keluar dari perangkat ini.')}};
  const submitText=(action:'answer'|'chat'|'complete'|'contribute'|'punishment')=>{
    if(!text.trim())return notify('Tulis satu-dua kalimat dulu ya 🙂');sendAction(action,{text:text.trim()});
  };
  const joinOrCreate=(event:FormEvent,action:'create'|'join')=>{event.preventDefault();roomMutation.mutate(action)};
  const isDark=dark;
  const partner=room?.members.find((member)=>member.id!==user?.id);
  const partnerOnline=!!partner&&Object.values(online).flat().some((presence)=>presence.user_id===partner.id);
  const game=room?.game;
  const gameState=game?.state||{};
  const answers=gameState.answers&&typeof gameState.answers==='object'?gameState.answers as Record<string,unknown>:{};
  const myAnswer=game?.game_type==='guess_me'?(Number(gameState.owner_seat)===room?.seat?gameState.secret_answer:gameState.guess_answer):(user?answers[user.id]:undefined);
  const allAnswered=game?.game_type==='guess_me'?!!gameState.secret_answer&&!!gameState.guess_answer:!!room&&room.members.length===2&&room.members.every((member)=>Object.hasOwn(answers,member.id));
  const prompt=String(gameState.prompt||'');
  const level=Math.min(20,Math.floor((room?.room.xp||0)/100)+1);
  const levelIndex=Math.max(0,level-1);
  const dailyQuestion=useMemo(()=>{
    let available=questionRows.filter((item)=>filterDeep||item.category!=='🌙 Deep');
    if(category!=='Semua kategori')available=available.filter((item)=>item.category===category);
    if(!available.length)available=questionRows.filter((item)=>item.category!=='🌙 Deep');
    const day=Math.floor(Date.now()/86_400_000);
    return available[day%available.length];
  },[category,filterDeep]);
  const themeToggle=<button className="icon-button" aria-label="Ganti tema" onClick={()=>setDark(!isDark)}>{isDark?'☀️':'🌙'}</button>;

  if(!authReady||!client) return <main className="center-stage"><div className="loading-orb">💌</div><p>{configError?'Koneksi belum siap':'Menyambungkan kembali ke ruang kalian…'}</p>{configError&&<><p className="muted">{configError}</p><button className="button primary" onClick={()=>window.location.reload()}>Coba lagi</button></>}</main>;
  if(!user) return <main className="page-shell">
    <header className="topbar"><a className="brand" href="#home"><span className="brand-mark">💌</span><span>jauh<span className="brand-pink">dekat</span><small>ruang kecil buat kita</small></span></a>{themeToggle}</header>
    <section className="hero"><span className="eyebrow">SEDIKIT LEBIH DEKAT, SATU KARTU SEKALI</span><h1>Ruang kecil<br/>buat <em>kita berdua.</em></h1><p>Obrolan receh, cerita random, dan hal-hal kecil yang bikin kamu terasa dekat meski lagi jauh.</p></section>
    <section className="entry-grid">
      <form className="card entry-card" onSubmit={(event)=>event.preventDefault()}>
        <h2>Mulai main bareng 💗</h2><p>Masuk pakai akun Google, atau bikin akun tamu yang aman untuk mulai.</p>
        {configError&&<div className="notice error">{configError}</div>}
        <label className="field-label">Nama panggilan<input className="field" maxLength={24} value={name} onChange={(event)=>setName(event.target.value)} placeholder="Contoh: Rara" /></label>
        <div><span className="field-label">Pilih avatar</span><div className="avatar-grid">{AVATARS.map((item)=><button type="button" className={`avatar-choice ${avatar===item?'selected':''}`} key={item} onClick={()=>setAvatar(item)} aria-label={`Pilih avatar ${item}`}>{item}</button>)}</div></div>
        <div className="entry-actions"><button className="button primary" type="button" disabled={accountMutation.isPending} onClick={()=>{if(name.trim())localStorage.setItem('ldr_name',name.trim());accountMutation.mutate('guest')}}>{accountMutation.isPending?'Menyiapkan…':'Lanjut sebagai tamu'}</button><button className="button soft" type="button" disabled={accountMutation.isPending} onClick={()=>accountMutation.mutate('google')}>Masuk dengan Google</button></div>
        <details className="join-details"><summary>Sudah ada kode room?</summary><div className="join-row"><input className="field code-field" maxLength={6} value={roomCode} onChange={(event)=>setRoomCode(event.target.value.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g,''))} placeholder="KODE" aria-label="Kode room"/><button className="button soft" type="button" disabled={roomMutation.isPending} onClick={()=>roomMutation.mutate('join')}>Gabung</button></div></details>
        {configError&&<button type="button" className="text-button" onClick={()=>window.location.reload()}>Coba sambungkan lagi</button>}
        <p className="tiny">Room hanya punya dua kursi. Kode cukup dibagikan ke pasanganmu aja 💌</p>
      </form>
      <aside className="card welcome-card"><div className="welcome-emoji">🌷</div><h2>Jauh jaraknya,<br/>dekat ceritanya.</h2><p>Bisa main saat sama-sama online, atau jawab pelan-pelan lewat mode asinkron. Progres kalian disimpan di room.</p><span className="badge">🔒 khusus 2 pemain</span><div className="feature-pills"><span>💬 obrolan</span><span>🎲 game</span><span>🫙 kenangan</span></div></aside>
    </section>
    <footer>Jauh Dekat dibuat buat ngobrol, ketawa, dan saling dengerin. 🌤️</footer>
    {toast&&<div className="toast" role="status">{toast}</div>}
  </main>;

  if(roomQuery.isPending) return <main className="center-stage"><div className="loading-orb">💌</div><h2>Menyambungkan kembali…</h2><p>Memulihkan akun, room, dan sesi game dari server.</p></main>;
  if(roomQuery.isError) return <main className="center-stage"><div className="loading-orb">☁️</div><h2>Jaringan lagi ngambek</h2><p>{messageOf(roomQuery.error)} Room kamu tetap tersimpan di server.</p><button className="button primary" onClick={()=>void roomQuery.refetch()}>Coba sambungkan lagi</button><button className="text-button" onClick={()=>void signOut()}>Keluar akun</button></main>;

  if(!room) return <main className="page-shell">
    <header className="topbar"><a className="brand" href="#home"><span className="brand-mark">💌</span><span>jauh<span className="brand-pink">dekat</span><small>ruang kecil buat kita</small></span></a><div className="top-controls"><span className="status-pill">{user.is_anonymous?'akun tamu':'akun Google'}</span>{themeToggle}</div></header>
    <section className="hero compact"><span className="eyebrow">ROOM-NYA TINGGAL DIBUAT</span><h1>Satu kode,<br/><em>dua kursi.</em></h1><p>Yang bikin room bagikan kodenya. Pasangan masuk dari perangkat lain dengan akun sendiri.</p></section>
    <section className="entry-grid"><form className="card entry-card" onSubmit={(event)=>joinOrCreate(event,'create')}>
      <h2>Bikin ruang kalian 💗</h2><label className="field-label">Nama panggilan<input className="field" maxLength={24} value={name} onChange={(event)=>setName(event.target.value)} placeholder="Nama yang kamu suka dipanggil"/></label>
      <div><span className="field-label">Pilih avatar</span><div className="avatar-grid">{AVATARS.map((item)=><button type="button" className={`avatar-choice ${avatar===item?'selected':''}`} key={item} onClick={()=>setAvatar(item)}>{item}</button>)}</div></div>
      <button className="button primary" type="submit" disabled={roomMutation.isPending}>{roomMutation.isPending?'Membuat room…':'Buat room'}</button>
      <div className="divider"><span>atau</span></div>
      <label className="field-label">Kode dari pasangan<div className="join-row"><input className="field code-field" maxLength={6} value={roomCode} onChange={(event)=>setRoomCode(event.target.value.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g,''))} placeholder="6 KARAKTER"/><button type="button" className="button soft" onClick={()=>roomMutation.mutate('join')} disabled={roomMutation.isPending}>Gabung</button></div></label>
      {roomMutation.isError&&<div className="notice error">{messageOf(roomMutation.error)}</div>}
      {user.is_anonymous&&<button type="button" className="button soft" onClick={()=>accountMutation.mutate('google')}>Simpan akun tamu ke Google</button>}
      <button type="button" className="text-button" onClick={()=>void signOut()}>Ganti akun</button>
    </form><aside className="card welcome-card"><div className="welcome-emoji">🪑🪑</div><h2>Cuma berdua,<br/>bebas jadi kalian.</h2><p>Setelah room dibuat, kirim kode ke pasangan. Satu akun hanya bisa masuk satu room supaya riwayatnya nggak ketuker.</p><span className="badge">🔐 Room private + Auth</span></aside></section>
    {toast&&<div className="toast" role="status">{toast}</div>}
  </main>;

  const self=room.members.find((member)=>member.id===user.id);
  const canPlay=room.members.length===2;
  const connection=status==='connected'?(partnerOnline?'Kalian online bareng':'Kamu online · pasangan offline'):status==='reconnecting'?'Menyambungkan…':status==='offline'?'Offline · room tersimpan':'Memeriksa koneksi';
  const settingsAsync=room.room.settings.async===true;
  const ldrDays=ldrSince?Math.max(0,Math.floor((Date.now()-new Date(ldrSince).getTime())/86_400_000)):null;
  const countdown=meetDate?Math.max(0,Math.ceil((new Date(`${meetDate}T00:00:00`).getTime()-new Date().setHours(0,0,0,0))/86_400_000)):null;
  const todayText=dailyQuestion?.prompt||'Apa hal kecil yang bikin harimu lebih enak hari ini?';
  const pairedChoices=game?.game_type==='would_you_rather'&&allAnswered;
  const matches=pairedChoices&&answers[user.id]===answers[partner!.id];
  const chooseGame=(id:GameType,dailyPrompt?:string,dailyId?:string)=>{if(switchingGame.current||startMutation.isPending||closeMutation.isPending)return; switchingGame.current=true; void(async()=>{try{if(room?.game)await closeMutation.mutateAsync();await startMutation.mutateAsync({game:id,dailyPrompt,dailyId})}catch(error){notify(messageOf(error))}finally{switchingGame.current=false}})()};
  const saveMemory=()=>{if(!game)return;const saved=`${prompt}${Object.values(answers).map((value)=>` · ${String(value)}`).join('')}`;memoryMutation.mutate(saved.slice(0,800))};
  const setAsyncMode=async()=>{const {error}=await client.rpc('update_ldr_settings',{p_settings:{async:!settingsAsync,deep_enabled:filterDeep,meet_date:meetDate||null,ldr_since:ldrSince||null}});if(error)notify(messageOf(error));else{notify(!settingsAsync?'Mode asinkron aktif 🌙':'Mode sinkron aktif ⚡');await refresh();await announce()}};
  const addQuestion=(event:FormEvent)=>{event.preventDefault();if(customQuestion.trim())customQuestionMutation.mutate(customQuestion.trim())};
  const submitVote=(vote:number|string)=>{sendAction('vote',typeof vote==='number'?{choice:String(vote)}:{choice:vote})};
  const todayDate=new Date().toLocaleDateString('id-ID',{weekday:'long',day:'numeric',month:'long'});
  const miniEvent=MINI_EVENTS[Math.floor(Date.now()/86_400_000)%MINI_EVENTS.length]!;

  return <main className="page-shell">
    <header className="topbar"><a className="brand" href="#home"><span className="brand-mark">💌</span><span>jauh<span className="brand-pink">dekat</span><small>ruang kecil buat kita</small></span></a><div className="top-controls"><span className={`status-pill ${status}`}>● {connection}</span>{themeToggle}<button className="icon-button" onClick={()=>void signOut()} aria-label="Keluar akun">↪</button></div></header>
    <section className="dashboard-hero card"><div><span className="eyebrow">KODE RUANG KALIAN</span><h1>Hai, {self?.name||name||'kalian'}! <span>✨</span></h1><p>Kode <strong className="room-code">{room.room.code}</strong><button className="copy-code" onClick={()=>{void navigator.clipboard?.writeText(room.room.code);notify('Kode room disalin 📋')}}>Salin</button><span className="dot-sep">·</span>{settingsAsync?'Asinkron 🌙':'Sinkron ⚡'} · kirim kodenya ke pasanganmu</p><div className="players-row">{room.members.map((member)=><div className="member-chip" key={member.id}><span>{member.avatar}</span>{member.name}<i className={online[member.id]?.length?'online-dot':''}/></div>)}{!partner&&<div className="member-chip waiting-chip">⌛ Menunggu pasangan gabung</div>}</div></div><div className="level-card"><div className="level-top"><span>LEVEL {level}</span><span>{LEVELS[levelIndex]}</span></div><div className="meter"><i style={{width:`${room.room.xp%100}%`}}/></div><small>{room.room.xp%100} / 100 XP · {room.room.streak} hari streak 🔥</small></div></section>
    <div className="quick-stats"><div className="stat-card"><span>💗</span><strong>{room.room.xp} XP</strong><small>petualangan kalian</small></div><div className="stat-card"><span>🌍</span><strong>{ldrDays===null?'Atur tanggal':`${ldrDays} hari`}</strong><small>perjalanan LDR</small></div><div className="stat-card"><span>🗓️</span><strong>{countdown===null?'Belum diatur':`${countdown} hari lagi`}</strong><small>sampai ketemu</small></div></div>
    <section className="daily-card card"><div className="daily-sun">☀️</div><div><span className="eyebrow">PERTANYAAN HARI INI · {todayDate}</span><h2>{todayText}</h2><p>Simpan untuk nanti atau jadikan bahan obrolan kalian hari ini.</p><p className="mini-event">🎁 Kejutan mini: {miniEvent}</p></div><button className="button soft" onClick={()=>chooseGame('deep_talk',todayText,dailyQuestion?.id)} disabled={!canPlay||startMutation.isPending}>Pakai pertanyaan ini</button></section>
    <div className="section-heading"><div><span className="eyebrow">PILIH SESUAI MOOD</span><h2>Mau main apa hari ini?</h2></div><button className="button soft" onClick={()=>void setAsyncMode()}>{settingsAsync?'🌙 Asinkron':'⚡ Sinkron'}</button></div>
    {!canPlay&&<div className="notice warm">Room masih menunggu kursi kedua. Begitu pasanganmu masuk, kartu-kartu ini langsung bisa dimainkan 💌</div>}
    <section className="game-grid">{GAMES.map((item)=><button key={item.id} className={`game-card ${game?.game_type===item.id?'current':''}`} disabled={!canPlay||startMutation.isPending} onClick={()=>chooseGame(item.id)}><span className="game-icon">{item.icon}</span><strong>{item.title}</strong><small>{item.description}</small></button>)}</section>
    {game&&<section className="play-layout">
      <article className="card play-card">
        <div className="play-heading"><div><span className="eyebrow">{GAMES.find((item)=>item.id===game.game_type)?.icon} SESI BERJALAN · RONDE {game.round_no}</span><h2>{GAMES.find((item)=>item.id===game.game_type)?.title}</h2></div><button className="icon-button" onClick={()=>closeMutation.mutate()} title="Tutup sesi">✕</button></div>
        {game.game_type==='snakes_ladders'?<SnakesBoard state={gameState} mySeat={room.seat} userId={user.id} members={room.members} onRoll={()=>sendAction('roll',{})} onPunishment={(answer)=>sendAction('punishment',{text:answer})} busy={actionMutation.isPending}/>
          :game.game_type==='tic_tac_toe'?<TicTacToe state={gameState} seat={room.seat} busy={actionMutation.isPending} onMove={(cell)=>sendAction('move',{cell})} onRematch={()=>sendAction('rematch',{})}/>
          :<>
            <div className="question-card"><span>💌 bahan cerita</span><h3>{prompt}</h3>{Array.isArray(gameState.options)&&gameState.options.length>0&&<div className="option-list">{(gameState.options as string[]).map((option,index)=><button key={index} className={`option-button ${choice===index?'selected':''}`} onClick={()=>setChoice(index)} disabled={typeof myAnswer!=='undefined'}>{option}</button>)}</div>}</div>
            {game.game_type==='would_you_rather'||game.game_type==='hot_takes'?<div className="answer-area">{typeof myAnswer!=='undefined'?<div className="notice warm">Pilihanmu sudah tersimpan. {allAnswered?'Buka hasilnya bareng 💗':'Nunggu pasangan pilih dulu ya…'}</div>:<button className="button primary" disabled={choice===null||actionMutation.isPending} onClick={()=>submitVote(choice!)}>{actionMutation.isPending?'Menyimpan…':'Kirim pilihanku 💌'}</button>}
            {allAnswered&&<div className={`match-result ${matches?'match':'different'}`}><strong>{game.game_type==='would_you_rather'?(matches?'100% kompak! 💞':'0% sama, 100% bahan obrolan 😄'):'Vote sudah kebuka!'}</strong><div>{room.members.map((member)=>{const vote=answers[member.id];const voteIndex=Number(vote);const options=gameState.options as string[]|undefined;return `${member.avatar} ${member.name}: ${options?.[voteIndex]||String(vote)}`}).join(' · ')}</div></div>}</div>
              :game.game_type==='dream_date'||game.game_type==='story_chain'?<><div className="message-feed">{Array.isArray(gameState.messages)&&gameState.messages.map((message,index)=>{const entry=message as {user_id?:string;text?:string};const sender=room.members.find((member)=>member.id===entry.user_id);return <div className={`chat-bubble ${entry.user_id===user.id?'mine':''}`} key={index}><small>{sender?.avatar} {sender?.name}</small>{entry.text}</div>})}</div><div className="composer"><input className="field" value={text} onChange={(event)=>setText(event.target.value)} maxLength={500} placeholder={game.game_type==='story_chain'?'Tambahkan satu kalimat…':'Ide kecilmu…'} onKeyDown={(event)=>{if(event.key==='Enter')submitText('chat')}}/><button className="button primary" disabled={!text.trim()||actionMutation.isPending} onClick={()=>submitText('chat')}>Kirim</button></div></>
              :<div className="answer-area">{typeof myAnswer!=='undefined'?<div className="notice warm">Jawabanmu tersimpan 💗 {allAnswered?'Kalian sudah sama-sama menjawab.':'Pasanganmu bisa membalas kapan saja.'}</div>:<><textarea className="field answer-input" maxLength={800} value={text} onChange={(event)=>setText(event.target.value)} placeholder={game.game_type==='guess_me'&&Number(gameState.owner_seat)===room.seat?'Jawab diam-diam dulu, pasanganmu nggak bisa lihat sebelum menebak…':game.game_type==='guess_me'?'Tebak jawaban pasanganmu…':'Ceritakan dari versimu…'} /><div className="answer-buttons"><button className="button primary" disabled={!text.trim()||actionMutation.isPending} onClick={()=>submitText(game.game_type==='ldr_challenge'?'complete':'answer')}>{game.game_type==='guess_me'&&Number(gameState.owner_seat)!==room.seat?'Kirim tebakan 🔎':'Simpan jawaban 💌'}</button>{game.game_type==='deep_talk'&&<button className="button soft" onClick={()=>{const question=window.prompt('Mau tanya balik apa? 💌');if(question?.trim())sendAction('chat',{text:`Tanya balik: ${question.trim()}`})}} disabled={actionMutation.isPending}>Tanya balik ↗</button>}<button className="text-button" onClick={()=>closeMutation.mutate()}>Skip dulu</button></div></>}
                {allAnswered&&<div className="revealed-answers"><strong>Jawaban kalian ✨</strong>{game.game_type==='guess_me'?<><div className="answer-reveal"><b>Jawaban rahasia</b><p>{String(gameState.secret_answer)}</p></div><div className="answer-reveal"><b>Tebakan pasangan</b><p>{String(gameState.guess_answer)}</p></div></>:room.members.map((member)=>{const value=answers[member.id];return value===undefined?null:<div className="answer-reveal" key={member.id}><b>{member.avatar} {member.name}</b><p>{String(value)}</p></div>})}</div>}
              </div>}
            {game.game_type==='hot_takes'&&allAnswered&&<div className="composer debate-composer"><input className="field" value={text} onChange={(event)=>setText(event.target.value)} maxLength={500} placeholder="Debat santai aja 😄" onKeyDown={(event)=>{if(event.key==='Enter')submitText('chat')}}/><button className="button primary" disabled={!text.trim()||actionMutation.isPending} onClick={()=>submitText('chat')}>Debat</button></div>}
          </>}
        {game.status==='round_complete'&&<div className="round-actions"><div className="notice success">Ronde selesai! Poin dan jawaban sudah tersimpan di server 💗</div><button className="button primary" onClick={()=>closeMutation.mutate()} disabled={closeMutation.isPending}>Pilih mode lain</button><button className="button soft" onClick={saveMemory} disabled={memoryMutation.isPending}>🫙 Simpan ke Memory Jar</button></div>}
      </article>
      <aside className="card side-panel"><div className="section-heading small-heading"><div><span className="eyebrow">ALBUM OBROLAN</span><h2>Memory Jar 🫙</h2></div><span className="badge">{memoriesQuery.data?.length||0}</span></div><p className="muted">Momen lucu atau jawaban yang pengin kalian baca lagi.</p>{memoriesQuery.data?.length?<div className="memory-list">{memoriesQuery.data.map((memory)=><div className="memory-item" key={memory.id}><p>{memory.body}</p><small>{new Date(memory.created_at).toLocaleDateString('id-ID')}</small></div>)}</div>:<div className="empty-memory">Belum ada kenangan yang disimpan. Ada yang berkesan? 💌</div>}
        <div className="settings-box"><h3>Atur ruang kalian ⚙️</h3><label className="field-label">LDR dimulai<input className="field" type="date" value={ldrSince} onChange={(event)=>setLdrSince(event.target.value)} /></label><label className="field-label">Ketemu berikutnya<input className="field" type="date" value={meetDate} onChange={(event)=>setMeetDate(event.target.value)} /></label><label className="toggle-row"><input type="checkbox" checked={filterDeep} onChange={(event)=>setFilterDeep(event.target.checked)}/> Tampilkan pertanyaan Deep</label><button className="button soft wide" onClick={()=>settingsMutation.mutate()} disabled={settingsMutation.isPending}>Simpan pengaturan</button></div>
        <form className="custom-question-form" onSubmit={addQuestion}><h3>Bikin pertanyaan buat pasangan 🧠</h3><div className="composer"><input className="field" value={customQuestion} maxLength={240} onChange={(event)=>setCustomQuestion(event.target.value)} placeholder="Contoh: makanan favoritku apa?"/><button className="button soft" disabled={!customQuestion.trim()||customQuestionMutation.isPending}>Tambah</button></div><small>{Array.isArray(room.room.settings.custom_questions)?room.room.settings.custom_questions.length:0} / 50 tersimpan untuk room kalian</small></form>
        <div className="history-section"><div className="section-heading small-heading"><div><span className="eyebrow">YANG PERNAH KALIAN MAININ</span><h2>Album obrolan 📚</h2></div><span className="badge">{historyQuery.data?.length||0}</span></div>{historyQuery.data?.length?<div className="memory-list">{historyQuery.data.map((item)=>{const state=item.state;const answers=state.answers&&typeof state.answers==='object'?Object.values(state.answers as Record<string,unknown>).map(String):[];const content=[typeof state.prompt==='string'?state.prompt:'',...answers,typeof state.secret_answer==='string'?state.secret_answer:'',typeof state.guess_answer==='string'?state.guess_answer:''].filter(Boolean);return <div className="memory-item" key={item.id}><b>{GAMES.find((entry)=>entry.id===item.game_type)?.title||item.game_type}</b><p>{content.join(' · ')||'Satu ronde kecil berdua ✨'}</p><small>{new Date(item.created_at).toLocaleDateString('id-ID')}</small></div>})}</div>:<div className="empty-memory">Sesi yang selesai akan muncul di sini, lengkap dengan jawaban kalian.</div>}</div>
        <details className="question-filters"><summary>Filter pertanyaan</summary><label className="field-label">Kategori<select className="field" value={category} onChange={(event)=>setCategory(event.target.value)}><option>Semua kategori</option>{CATEGORIES.filter((item)=>filterDeep||item!=='🌙 Deep').map((item)=><option key={item}>{item}</option>)}</select></label><label className="field-label">Kedalaman<select className="field" value={depth} onChange={(event)=>setDepth(Number(event.target.value))}><option value="1">Ringan</option><option value="2">Sedang</option><option value="3">Dalam</option></select></label></details>
      </aside>
    </section>}
    <footer>Koneksi putus sebentar? Nggak apa-apa. Room dan jawaban kalian tetap tersimpan di server. <button className="text-button" onClick={()=>void refresh()}>Cek sekarang</button></footer>
    {toast&&<div className="toast" role="status">{toast}</div>}
  </main>;
}

