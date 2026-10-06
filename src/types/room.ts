import { z } from 'zod';

export const RoomSnapshotSchema = z.object({
  room: z.object({
    id: z.string().uuid(), code: z.string().length(6), status: z.enum(['waiting','ready','playing','closed']),
    created_by: z.string().uuid(), settings: z.record(z.string(), z.unknown()), xp: z.number().int(), streak: z.number().int(),
    last_played_on: z.string().nullable(), created_at: z.string(), updated_at: z.string(),
  }),
  seat: z.union([z.literal(0),z.literal(1)]),
  members: z.array(z.object({ id: z.string().uuid(), name: z.string(), avatar: z.string(), seat: z.number().int() })).max(2),
  game: z.object({
    id: z.string().uuid(), room_id: z.string().uuid(), game_type: z.string(), status: z.enum(['playing','round_complete','finished']),
    round_no: z.number().int(), state: z.record(z.string(), z.unknown()), created_by: z.string().uuid(), created_at: z.string(), updated_at: z.string(),
  }).nullable(),
}).nullable();

export type RoomSnapshot = NonNullable<z.infer<typeof RoomSnapshotSchema>>;
export type GameType = 'guess_me'|'would_you_rather'|'deep_talk'|'hot_takes'|'ldr_challenge'|'couple_quiz'|'dream_date'|'story_chain'|'tic_tac_toe'|'snakes_ladders';
