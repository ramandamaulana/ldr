import { describe, expect, it } from 'vitest';
import { messageOf } from './errors';

describe('user-facing backend errors', () => {
  it('explains that the room schema migration is missing', () => {
    expect(messageOf({ code: 'PGRST202', message: 'Could not find the function public.get_my_room' }))
      .toContain('Jalankan setup.sql versi terbaru');
  });

  it('explains how to enable guest sign-in', () => {
    expect(messageOf(new Error('Anonymous sign-ins are disabled')))
      .toContain('aktifkan Anonymous Sign-Ins');
  });

  it('explains how to configure Google OAuth', () => {
    expect(messageOf(new Error('Unsupported provider: provider is not enabled')))
      .toContain('provider Google');
  });

  it('explains redirect allowlist errors without hiding other backend messages', () => {
    expect(messageOf(new Error('redirect_uri_mismatch')))
      .toContain('Redirect URLs Supabase');
    expect(messageOf(new Error('Kode room tidak ditemukan atau sudah ditutup.')))
      .toBe('Kode room tidak ditemukan atau sudah ditutup.');
  });
});
