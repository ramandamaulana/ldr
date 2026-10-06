import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const sql=readFileSync(new URL('../supabase/migrations/20261006000100_auth_rooms.sql',import.meta.url),'utf8');

describe('Supabase authorization contract',()=>{
  it('limits membership to two unique seats and one room per identity',()=>{
    expect(sql).toMatch(/unique \(room_id,seat\)/);
    expect(sql).toMatch(/unique \(user_id\)/);
    expect(sql).toMatch(/member_count >= 2/);
    expect(sql).toMatch(/for update/);
    expect(sql).toMatch(/attempts>=10/);
    expect(sql).toMatch(/interval '15 minutes'/);
  });

  it('enables RLS and prevents anonymous execution of old token RPCs',()=>{
    expect(sql.match(/enable row level security/g)?.length).toBeGreaterThanOrEqual(7);
    expect(sql).toMatch(/revoke all on function %s from public,anon,authenticated/);
    expect(sql).toMatch(/auth\.uid\(\)/);
    expect(sql).toMatch(/grant execute on function public\.create_ldr_room.*to authenticated/s);
    expect(sql).not.toMatch(/grant execute on function public\.(?:create_ldr_room|join_ldr_room|save_ldr_room).*to anon/);
  });

  it('serializes session actions and stores idempotency keys in PostgreSQL',()=>{
    expect(sql).toMatch(/unique\(session_id,idempotency_key\)/);
    expect(sql).toMatch(/from public\.game_sessions where id=p_session_id for update/);
    expect(sql).toMatch(/if p_idempotency_key is null/);
    expect(sql).toMatch(/random\(\)\*6/);
  });

  it('projects the guess answer privately until the second player responds',()=>{
    expect(sql).toMatch(/session_row\.state->>'guess_answer' is null/);
    expect(sql).toMatch(/session_row\.state-'secret_answer'/);
    expect(sql).toMatch(/state_json->>'secret_answer' is null/);
  });
});
