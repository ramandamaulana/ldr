import { useEffect, useState, type Dispatch, type SetStateAction } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { SupabaseClient, User } from '@supabase/supabase-js';
import { RoomSnapshotSchema, type GameType } from '../../types/room';

export type ConnectionStatus='connecting'|'connected'|'reconnecting'|'offline';
export type PresenceMap=Record<string,{user_id?:string;online_at?:string}[]>;
type GameHistoryRow={id:string;game_type:GameType;status:string;round_no:number;state:Record<string,unknown>;created_at:string};
type SavedMemory={id:string;body:string;created_at:string};

export function useRoomData(client:SupabaseClient|null,user:User|null,status:ConnectionStatus,setStatus:Dispatch<SetStateAction<ConnectionStatus>>){
  const queryClient=useQueryClient();
  const [online,setOnline]=useState<PresenceMap>({});
  const roomQuery=useQuery({
    queryKey:['my-room',user?.id],enabled:!!client&&!!user,
    queryFn:async()=>{
      const {data,error}=await client!.rpc('get_my_room');if(error)throw error;
      const parsed=RoomSnapshotSchema.safeParse(data);
      if(!parsed.success)throw new Error('Data room dari server belum sesuai. Jalankan setup Supabase v2 terbaru.');
      return parsed.data;
    },refetchInterval:status==='connected'?20_000:8_000,
  });
  const room=roomQuery.data;
  const memoriesQuery=useQuery({queryKey:['memories',room?.room.id],enabled:!!client&&!!room,queryFn:async()=>{
    const {data,error}=await client!.from('room_memories').select('id,body,created_at').eq('room_id',room!.room.id).order('created_at',{ascending:false}).limit(30);
    if(error)throw error;return data as SavedMemory[];
  }});
  const historyQuery=useQuery({queryKey:['game-history',room?.room.id],enabled:!!client&&!!room,queryFn:async()=>{
    const {data,error}=await client!.rpc('get_ldr_game_history');if(error)throw error;return data as GameHistoryRow[];
  }});
  const usedQuery=useQuery({queryKey:['used-questions',room?.room.id],enabled:!!client&&!!room,queryFn:async()=>{
    const {data,error}=await client!.rpc('get_used_question_ids');if(error)throw error;return data as string[];
  }});

  useEffect(()=>{
    if(!client||!user||!room)return;
    let alive=true;
    const channel=client.channel(`ldr-room:${room.room.id}`,{config:{private:true,presence:{key:user.id},broadcast:{self:false}}});
    channel.on('broadcast',{event:'room_changed'},()=>{
      void queryClient.invalidateQueries({queryKey:['my-room',user.id]});
      void queryClient.invalidateQueries({queryKey:['memories',room.room.id]});
      void queryClient.invalidateQueries({queryKey:['used-questions',room.room.id]});
      void queryClient.invalidateQueries({queryKey:['game-history',room.room.id]});
    });
    channel.on('presence',{event:'sync'},()=>{if(alive)setOnline(channel.presenceState() as PresenceMap)});
    channel.subscribe(async(channelStatus)=>{
      if(!alive)return;
      if(channelStatus==='SUBSCRIBED'){
        setStatus('connected');
        await channel.track({user_id:user.id,online_at:new Date().toISOString()});
        void queryClient.invalidateQueries({queryKey:['my-room',user.id]});
      }else if(channelStatus==='CHANNEL_ERROR'||channelStatus==='TIMED_OUT')setStatus(navigator.onLine?'reconnecting':'offline');
      else if(channelStatus==='CLOSED')setStatus('reconnecting');
    });
    return()=>{alive=false;setStatus('offline');void client.removeChannel(channel)};
  },[client,user?.id,room?.room.id,queryClient,setStatus]);
  useEffect(()=>{
    const offline=()=>setStatus('offline');
    const recover=()=>{
      setStatus('reconnecting');
      if(!user)return;
      void queryClient.invalidateQueries({queryKey:['my-room',user.id]});
      if(room){
        void queryClient.invalidateQueries({queryKey:['memories',room.room.id]});
        void queryClient.invalidateQueries({queryKey:['used-questions',room.room.id]});
        void queryClient.invalidateQueries({queryKey:['game-history',room.room.id]});
      }
    };
    const becameVisible=()=>{if(document.visibilityState==='visible'&&navigator.onLine)recover()};
    window.addEventListener('offline',offline);window.addEventListener('online',recover);
    document.addEventListener('visibilitychange',becameVisible);
    return()=>{window.removeEventListener('offline',offline);window.removeEventListener('online',recover);document.removeEventListener('visibilitychange',becameVisible)};
  },[queryClient,room?.room.id,setStatus,user?.id]);

  return {roomQuery,room,memoriesQuery,historyQuery,usedQuery,online};
}
