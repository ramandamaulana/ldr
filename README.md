# Jauh Dekat 💌

Ruang main dan obrolan pasangan LDR. Frontend sekarang React + TypeScript + Vite; Supabase Auth mengelola identitas, PostgreSQL/RPC menjadi sumber state game, dan Realtime hanya mengirim sinyal perubahan serta Presence.

## Menyiapkan Supabase v2

> SQL v2 menonaktifkan RPC token lama yang memberi akses `anon`. Siapkan build aplikasi baru terlebih dahulu dan lakukan migrasi saat siap mengganti versi lama. Data tabel `ldr_rooms` lama tidak dihapus, tetapi room dan token lama tidak otomatis dipindahkan karena token lama tidak terhubung ke akun Auth. Setelah migrasi, buat room baru dengan akun Auth masing-masing.

1. Di Supabase **Authentication → Sign In / Providers**, aktifkan **Anonymous Sign-Ins** untuk mode akun tamu.
2. Kalau ingin Google login, aktifkan provider Google dan isi OAuth Client ID/Secret di dashboard Supabase. Tambahkan URL lokal dan URL Render ke **Authentication → URL Configuration → Redirect URLs**, misalnya `http://localhost:3000/**` dan `https://NAMA-APP.onrender.com/**`.
3. Buka **SQL Editor → New query**, salin seluruh isi [`setup.sql`](./setup.sql), lalu jalankan. Skema sumbernya ada di [`supabase/migrations/20261006000100_auth_rooms.sql`](./supabase/migrations/20261006000100_auth_rooms.sql).
4. Atur environment lokal di `.env.local` (jangan commit):

   ```env
   SUPABASE_URL=https://PROJECT-REF.supabase.co
   SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
   ```

   Publishable key lama `anon` juga bisa dipakai dengan nama `SUPABASE_ANON_KEY`. Jangan taruh `service_role`/secret key di aplikasi atau hosting frontend.

5. Jalankan `npm install`, `npm run dev`, lalu buka `http://localhost:3000`.

## Deploy ke Render

Untuk Web Service Node yang melayani app hasil build, gunakan:

- **Build Command:** `npm install && npm run build`
- **Start Command:** `npm start`
- **Environment:** `SUPABASE_URL` dan `SUPABASE_PUBLISHABLE_KEY`

Render membaca environment langsung dari pengaturan service; file `.env` tidak perlu diunggah ke GitHub. Setelah deploy, cek `/healthz` dan buka URL aplikasi. OAuth Google perlu URL Render yang sama di Redirect URLs Supabase dan daftar Authorized Redirect URIs Google.

## Cara main

1. Setiap orang masuk dari perangkatnya sendiri memakai Google atau **Lanjut sebagai tamu**. Tamu disimpan oleh Supabase Auth di browser itu.
2. Pemain pertama membuat room dan membagikan kode enam karakter. Pemain kedua masuk dengan kode itu. Database mengunci maksimum dua anggota dan satu akun hanya boleh berada di satu room.
3. Pilih mode. Refresh/reconnect memuat room dan game aktif dari database. Sesi game, jawaban, Memory Jar, streak, dan XP tersimpan di server.

Google OAuth mengembalikan pemain ke app; membership aktif dipulihkan dari `auth.uid()`. Anonymous Auth cocok untuk mulai cepat di satu browser. Untuk pemulihan akun lintas perangkat atau browser yang data situsnya terhapus, pakai Google login.

## Arsitektur dan keamanan

- `src/app/App.tsx`: alur auth, bootstrap, room, UI game, dan query server.
- `src/features/games/registry.ts` + `questions.json`: canonical game IDs dan bank pertanyaan yang dapat diedit. Tiap tujuh kategori berisi 20 pertanyaan, disusun dari kedalaman ringan ke dalam.
- `src/lib/supabase.ts`: singleton client, Auth PKCE/session persist, dan batas waktu request.
- `supabase/migrations/...sql`: profiles, rooms, room_members, game_sessions, game_actions, Memory Jar, RLS, RPC, dan aturan private Realtime.
- RPC mutasi memeriksa `auth.uid()` dan membership. `game_sessions` tidak dapat dibaca langsung; `get_my_room()` memproyeksikan jawaban rahasia Tebak Aku sampai pasangan mengirim tebakan.
- Satu sesi aktif per room, dua seat unik, satu room per akun. Aksi game dikunci di transaksi PostgreSQL; Tic-Tac-Toe, Ular Tangga, giliran, skor, XP, dan idempotency dicek server-side.
- Presence hanya menandai online. Membership tetap berasal dari database; Broadcast membawa sinyal tanpa jawaban, lalu app refetch state kanonis.
- Realtime channel dibuat satu kali per room dan dibersihkan saat unmount. Refetch periodik tetap aktif sebagai fallback reconnect.

## Perintah pemeriksaan

```bash
npm run typecheck
npm run lint
npm test
npm run build
npx playwright install chromium   # sekali, untuk browser E2E
npm run test:e2e
```

Playwright menguji konteks browser terpisah dan tampilan mobile. Uji dua akun sungguhan, OAuth, race-condition pada database Supabase, dan reconnect WebSocket produksi perlu dijalankan setelah SQL v2 dipasang; tes lokal tanpa kredensial tidak mengklaim sudah memverifikasi layanan live.

## Menambah pertanyaan

Tambahkan objek ke `src/features/games/questions.json`:

```json
{ "q": "Pertanyaan baru kamu?", "d": 1 }
```

`d` bernilai `1` (ringan), `2` (sedang), atau `3` (dalam). Pertanyaan tambahan untuk Kuis Kita bisa dimasukkan dari panel game dan disimpan bersama room. Pertanyaan yang sudah dijawab dicatat di `room_question_uses` supaya kartu berikutnya tidak berulang.

## Batasan yang diketahui

- Google OAuth hanya bekerja setelah provider, kredensial Google, dan redirect URL di dashboard disiapkan.
- Room/token lama sengaja tidak diimpor ke identitas Auth baru. Data lama tetap berada di tabel lama, tetapi UI v2 memakai room baru.
- AI tidak dikonfigurasi; generator AI eksternal memerlukan endpoint/key terpisah. Bank lokal, pilihan acak, dan pertanyaan harian tetap tersedia.
- Voice note dan bukti foto misi dikirim melalui aplikasi chat; app tidak mengunggah media.
- Tema gelap dan 20 nama level sudah ada. Unlock tema/badge khusus dan leaderboard XP lanjutan belum dibuat.
- Ular Tangga sudah memakai dadu/posisi/penalty server-side, tetapi belum mencakup animasi papan khusus, kartu hadiah, atau skor misi tambahan dari versi lama.
