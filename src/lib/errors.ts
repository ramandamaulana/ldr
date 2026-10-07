type ErrorShape = { message?: unknown; code?: unknown; status?: unknown };

export function messageOf(error: unknown) {
  const shaped = typeof error === 'object' && error !== null ? error as ErrorShape : undefined;
  const message = error instanceof Error
    ? error.message
    : typeof shaped?.message === 'string' ? shaped.message : '';
  const code = typeof shaped?.code === 'string' ? shaped.code : '';
  const normalized = `${code} ${message}`.toLowerCase();

  if (code === 'PGRST202' || /could not find the function public\.(create_ldr_room|join_ldr_room|get_my_room)/i.test(message)) {
    return 'Database game belum disiapkan. Jalankan setup.sql versi terbaru di Supabase → SQL Editor, lalu muat ulang halaman.';
  }
  if (/anonymous sign-?ins? (are|is) disabled|anonymous users? (are|is) disabled|anonymous provider.*not enabled/.test(normalized)) {
    return 'Login tamu belum diaktifkan. Buka Supabase → Authentication → Sign In / Providers, lalu aktifkan Anonymous Sign-Ins.';
  }
  if (/unsupported provider|provider is not enabled|provider.*not enabled|provider_disabled/.test(normalized)) {
    return 'Login Google belum aktif di Supabase. Aktifkan provider Google dan isi OAuth Client ID serta Secret terlebih dahulu.';
  }
  if (/redirect_uri_mismatch|redirect url.*not allowed|redirect.*not whitelisted|requested path is invalid/.test(normalized)) {
    return 'Alamat kembali login belum diizinkan. Tambahkan URL website ini ke Redirect URLs Supabase dan cek Authorized Redirect URI Google.';
  }
  if (code === '42P01' || /relation .* does not exist|schema cache/.test(normalized)) {
    return 'Tabel game belum siap. Jalankan setup.sql versi terbaru di Supabase → SQL Editor, lalu muat ulang halaman.';
  }
  if (code === '28000' || /sesi login tidak ditemukan|not authenticated/.test(normalized)) {
    return 'Sesi login belum siap. Coba masuk lagi, lalu ulangi aksi tadi.';
  }
  if (code === '42501' || /row-level security|permission denied/.test(normalized)) {
    return 'Akun ini belum punya akses ke room tersebut. Pastikan kamu masuk dengan akun yang benar dan database sudah memakai setup.sql terbaru.';
  }

  return message || 'Ada kendala sebentar. Coba lagi ya.';
}
