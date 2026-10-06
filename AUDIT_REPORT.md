# Jauh Dekat — Audit & Refactor Report

Tanggal audit: 6 Oktober 2026  
Ruang lingkup: seluruh frontend lama, server Node, inisialisasi Supabase, tabel/RPC pada `setup.sql`, multiplayer, session restore, mini-game, dan pemeriksaan lokal.

## Ringkasan

Frontend satu file dipindahkan ke React + TypeScript + Vite. Alur identitas sekarang menggunakan Supabase Auth (Google OAuth atau akun anonim), keanggotaan room disimpan sebagai `auth.uid()`, dan state game dibaca kembali dari PostgreSQL. Realtime hanya memberi sinyal untuk refetch state kanonis serta status Presence.

Migrasi database v2 sudah ditulis, tetapi **belum dijalankan pada project Supabase live**. Karena identitas room lama berupa token buatan browser dan tidak punya relasi tepercaya ke akun Auth, room lama tidak diimpor otomatis. Data `ldr_rooms` lama tetap ada, tetapi RPC token lama dicabut dan aplikasi v2 meminta room baru.

## Temuan sebelum perubahan

### CRITICAL — Identitas dan otorisasi room tidak memakai Auth

- **Gejala:** refresh/reconnect dapat membuat pemain dianggap keluar; sesi bergantung pada token yang tersimpan di browser.
- **Akar masalah:** `index.html` membuat UUID/token client-side, sementara RPC di `setup.sql` memberi akses baca/tulis kepada `anon` dan mengotorisasi lewat token yang dikirim client.
- **Dampak:** kode room/token menjadi batas keamanan utama; tidak ada membership yang dikaitkan dengan `auth.uid()`.
- **Perbaikan:** tabel `profiles`, `rooms`, `room_members`; create/join memerlukan Auth; seat unik dan membership satu room per akun; RLS aktif; RPC lama dicabut dari `anon`/`authenticated`.
- **Berkas:** `index.html`, `setup.sql`, `supabase/migrations/20261006000100_auth_rooms.sql`, `src/lib/supabase.ts`, `src/app/App.tsx`.

### CRITICAL — `save_ldr_room` menerima snapshot JSONB besar dari browser

- **Gejala:** skor, turn, progres, jawaban, dan beberapa status game dapat berbeda atau tertimpa antarperangkat.
- **Akar masalah:** `save_ldr_room` menggabungkan JSONB yang disusun client; sejumlah aturan perlindungan hanya mencakup field tertentu, bukan seluruh transisi game.
- **Dampak:** database tidak benar-benar authoritative; client yang dimodifikasi dapat mencoba mengubah state di luar giliran.
- **Perbaikan:** akses tabel sensitif langsung dicabut; mutasi v2 lewat RPC transaksi yang memeriksa Auth, room membership, sesi, giliran, nilai input, dan action id. `game_sessions` dibaca melalui RPC projection saja.
- **Berkas:** `setup.sql`, `supabase/migrations/20261006000100_auth_rooms.sql`.

### HIGH — Restore sesi menganggap kegagalan jaringan sebagai sesi rusak

- **Gejala:** pemain bisa kembali ke lobby atau harus login/masuk room lagi setelah refresh atau jaringan putus.
- **Akar masalah:** jalur restore lama mengaitkan token custom dengan panggilan RPC; kegagalan sementara dapat menghapus/meninggalkan sesi dan cache lokal ikut dipakai sebagai sumber state.
- **Perbaikan:** bootstrap menunggu `getSession()` dan `onAuthStateChange()`; query `get_my_room()` memulihkan membership dari database. Error jaringan menampilkan status sambung ulang dan tidak menghapus Auth/session. Kegagalan RPC memicu refetch canonical state.
- **Berkas:** `src/app/App.tsx`, `src/lib/supabase.ts`.

### HIGH — Race condition dan aksi ganda tidak konsisten

- **Gejala:** aksi berdekatan dapat menghasilkan state basi, roll/move yang berbeda, atau progres ganda.
- **Akar masalah:** save queue dan merge JSONB client bukan pengganti transaksi; tidak semua aksi lama punya kunci idempotency yang divalidasi database.
- **Perbaikan:** lock room/session dengan `FOR UPDATE`, satu sesi aktif per room, `game_actions` dengan unique `(session_id,idempotency_key)`, action key diulang ketika retry, dan state game ditulis di transaksi PostgreSQL.
- **Berkas:** `setup.sql`, `src/app/App.tsx`.

### HIGH — State dua game kompetitif tidak selalu authoritative

- **Gejala:** board/turn/dice dapat tertinggal setelah refresh atau berbeda antarperangkat.
- **Akar masalah:** implementasi lama mencampur state local JavaScript dan RPC; operasi server belum menjadi satu kontrak aksi canonical untuk semua mode.
- **Perbaikan:** Tic-Tac-Toe memvalidasi sel, turn, win/draw/rematch di RPC. Ular Tangga memilih dadu dan menghitung posisi/ular/tangga/penalty di transaksi server. Keduanya direstore dari `game_sessions`.
- **Berkas:** `setup.sql`, `src/app/App.tsx`.

### HIGH — Realtime/presence dapat memberi status yang menyesatkan

- **Gejala:** status pasangan masih “menunggu” atau perangkat berbeda meski pasangan sudah masuk; reconnect dapat terlihat seperti keluar room.
- **Akar masalah:** channel client-side dan polling lama tidak menentukan membership dari database; pemulihan state dan status socket bercampur.
- **Perbaikan:** membership dibaca dari `room_members`; private Broadcast hanya mengirim sinyal lalu client refetch; private Presence hanya untuk online status. Channel dibersihkan pada unmount dan polling tetap menjadi fallback.
- **Berkas:** `supabase/migrations/20261006000100_auth_rooms.sql`, `src/app/App.tsx`.

### MEDIUM — Identitas game dan validasi payload tersebar

- **Gejala:** mode/pertanyaan berpotensi salah silang atau identifier lama berbeda format.
- **Akar masalah:** katalog, aturan, rendering, dan data tersimpan berada di file JavaScript yang sama tanpa tipe kontrak.
- **Perbaikan:** registry memakai ID canonical (`deep_talk`, `would_you_rather`, `hot_takes`, `tic_tac_toe`, `snakes_ladders`, dan lainnya); payload room divalidasi dengan Zod; bank dipisahkan ke JSON.
- **Berkas:** `src/features/games/registry.ts`, `src/features/games/questions.json`, `src/types/room.ts`.

### MEDIUM — Percobaan menebak kode room tidak dibatasi

- **Akar masalah:** RPC join lama tidak mencatat percobaan kode.
- **Perbaikan:** v2 membatasi 10 upaya per akun dalam 15 menit. Batas ini berlaku per akun Auth; anon sign-in dapat membuat identitas baru, jadi mitigasi per-IP/CAPTCHA masih perlu bila layanan menghadapi penyalahgunaan.
- **Berkas:** `supabase/migrations/20261006000100_auth_rooms.sql`.

### LOW — Sulit mereproduksi bug UI dan deploy

- **Akar masalah:** UI hampir seluruhnya berada di `index.html`; tidak ada build/type/lint/test pipeline atau health route produksi.
- **Perbaikan:** React + TypeScript + Vite, TanStack Query, Zod, Vitest, Playwright, build chunking, `server.mjs` melayani `dist`, `/healthz`, dan endpoint konfigurasi browser-safe.
- **Berkas:** `package.json`, `src/`, `vite.config.ts`, `server.mjs`, `tests/`, `e2e/`.

## Perubahan database dan RPC

- Tabel baru: `profiles`, `rooms`, `room_members`, `room_join_attempts`, `game_sessions`, `game_actions`, `room_question_uses`, `room_memories`.
- Constraint: maksimum dua seat melalui `unique(room_id,seat)` plus lock saat join; `unique(user_id)` membatasi satu room per akun; partial unique index membatasi satu sesi aktif per room.
- RLS: aktif pada semua tabel baru. Session/action/question-use tidak dapat dibaca langsung oleh client. Tidak ada grant mutasi tabel game kepada `anon`.
- RPC v2: `create_ldr_room`, `join_ldr_room`, `get_my_room`, `start_ldr_game`, `submit_ldr_action`, `close_ldr_game`, `update_ldr_settings`, `add_ldr_custom_question`, `save_ldr_memory`, `get_used_question_ids`, `get_ldr_game_history`, dan `notify_ldr_room`.
- RPC lama yang diaudit dan dicabut: `create_ldr_room` overload token lama, `join_ldr_room` token lama, `get_ldr_room`, `save_ldr_room`, `set_room_game_mode`, `start_snakes_ladders`, `roll_snakes_ladders`, `complete_snake_punishment`, `play_ttt_move`, `rematch_ttt`, `return_to_room`, serta versi idempotent token lama.
- Semua fungsi `SECURITY DEFINER` baru menggunakan `search_path=''` dan referensi tabel/schema berkualifikasi. Mutasi menerima parameter SQL terikat; tidak ada dynamic SQL dari input pengguna.
- Jawaban rahasia Tebak Aku dikeluarkan dari projection pemain penebak sampai jawaban kedua tersimpan.

## Berkas utama yang berubah

- `index.html` — entry Vite baru.
- `src/app/App.tsx` — OAuth/guest Auth, restore, room, multiplayer, game, setting, Memory Jar, album jawaban.
- `src/features/games/registry.ts` dan `questions.json` — 10 mode canonical, 140 pertanyaan, tingkat kedalaman terurut.
- `src/lib/supabase.ts`, `src/types/room.ts`, `src/styles.css` — client, validasi, tema responsive/dark.
- `supabase/migrations/20261006000100_auth_rooms.sql` dan `setup.sql` — skema/RLS/RPC v2.
- `server.mjs`, `vite.config.ts`, `package.json`, `README.md`, `.gitignore` — config runtime, build/deploy, petunjuk.
- `src/features/games/registry.test.ts`, `tests/security-contract.test.ts`, `e2e/room-entry.spec.ts` — tes baru. Tes Node lama yang mengunci asumsi satu-file dihapus.

## Pemeriksaan yang lulus

- `npm run typecheck` — lulus.
- `npm run lint` — lulus.
- `npm test` — 7 tes lulus (bank/registry, aturan Tic-Tac-Toe, kontrak RLS/membership/idempotency/projection).
- `npm run build` — lulus; bundle dipecah per vendor.
- `npm audit` — 0 vulnerability pada dependency tree.
- `npm run test:e2e` — 2 tes lulus memakai dua BrowserContext terpisah dan viewport mobile. Browser lokal Chrome digunakan melalui `CHROME_PATH` karena unduhan browser Playwright dari CDN timeout.
- Smoke server produksi Node lokal: `/healthz`, `/`, `/.well-known/ldr-config`, dan `/setup.sql` merespons HTTP 200; app build dan dua environment key tersedia tanpa dicetak.
- `git diff --check` — lulus; hanya peringatan konversi line ending LF/CRLF.

## Belum terverifikasi / batasan

- `setup.sql` **belum dieksekusi** pada Supabase; validasi SQL di atas adalah audit statis dan tes kontrak, bukan tes PostgreSQL live.
- Google OAuth, anonymous sign-in di provider project, policies Realtime, dan redirect URL belum diuji terhadap project Supabase sungguhan.
- Playwright saat ini menguji shell UI dalam dua konteks, bukan create/join/game/realtime dengan dua akun Supabase nyata. Race test terhadap transaksi PostgreSQL juga menunggu migration terpasang.
- Migrasi sengaja tidak mengikat token UUID lama ke akun Google/tamu baru. Siapkan room v2 baru; jangan hapus tabel lama sebelum memutuskan retensi datanya.
- Belum ada migrasi pertanyaan/kustom lama, tombol leave/reassign room, upload voice note/foto, generator AI, badge/unlock tema, leaderboard, atau rotasi mode otomatis.
- Join throttling sekarang per Auth user, belum per-IP. Room code 6 karakter tetap harus dibagikan privat.
- Karena fungsi lama dicabut, jalankan migrasi dan deploy build baru secara terkoordinasi. Simpan backup database terlebih dahulu dan siapkan project uji sebelum menjalankan SQL pada room live.
