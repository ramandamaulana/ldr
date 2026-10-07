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
- `npm test` — saat audit lanjutan 12 tes lulus (bank/registry, aturan Tic-Tac-Toe, kontrak RLS/membership/idempotency/projection dan join throttle).
- `npm run build` — lulus; bundle dipecah per vendor.
- `npm audit` — 0 vulnerability pada dependency tree.
- `npm run test:e2e` — 2 tes lulus memakai dua BrowserContext terpisah dan viewport mobile. Browser lokal Chrome digunakan melalui `CHROME_PATH` karena unduhan browser Playwright dari CDN timeout.
- Smoke server produksi Node lokal sebelum audit lanjutan: `/healthz`, `/`, `/.well-known/ldr-config`, dan `/setup.sql` merespons HTTP 200; rute SQL publik kemudian dihapus.
- `git diff --check` — lulus; hanya peringatan konversi line ending LF/CRLF.

## Belum terverifikasi / batasan

- `setup.sql` **belum dieksekusi** pada Supabase; validasi SQL di atas adalah audit statis dan tes kontrak, bukan tes PostgreSQL live.
- OAuth/room/realtime live belum diuji end-to-end; Auth settings diperiksa kembali pada audit lanjutan.
- Playwright saat ini menguji shell UI dalam dua konteks, bukan create/join/game/realtime dengan dua akun Supabase nyata. Race test terhadap transaksi PostgreSQL juga menunggu migration terpasang.
- Migrasi sengaja tidak mengikat token UUID lama ke akun Google/tamu baru. Siapkan room v2 baru; jangan hapus tabel lama sebelum memutuskan retensi datanya.
- Belum ada migrasi pertanyaan/kustom lama, tombol leave/reassign room, upload voice note/foto, generator AI, badge/unlock tema, leaderboard, atau rotasi mode otomatis.
- Join throttling sekarang per Auth user, belum per-IP. Room code 6 karakter tetap harus dibagikan privat.
- Karena fungsi lama dicabut, jalankan migrasi dan deploy build baru secara terkoordinasi. Simpan backup database terlebih dahulu dan siapkan project uji sebelum menjalankan SQL pada room live.

## Audit lanjutan — 7 Oktober 2026

### Perbaikan lokal

- Bootstrap session tidak lagi menimpa event `SIGNED_IN`/`SIGNED_OUT` yang datang setelah pembacaan `getSession()` dimulai.
- Aksi ganti mode memakai satu guard dan menunggu mutasi start selesai; klik cepat tidak mengirim beberapa permintaan start dari UI yang sama.
- Saat jaringan pulih atau tab kembali terlihat, room, riwayat, Memory Jar, dan pertanyaan terpakai langsung diminta ulang dari server.
- Join room mengembalikan kode error terstruktur untuk room tidak ditemukan/penuh dan rate limit. Ini membiarkan transaksi gagal tersimpan sehingga penghitung percobaan kode benar-benar bekerja.
- Path JSONB posisi Ular Tangga dibentuk sebagai `text[]`, sesuai signature `jsonb_set` PostgreSQL.
- `setup.sql` dan migration tetap identik setelah perbaikan.
- Endpoint publik `/setup.sql` dihapus. Folder migration dan `.env` juga tidak disajikan server; `.env` lokal tetap ada tetapi dihapus dari Git index agar perubahan berikutnya tidak mengikutsertakannya.

### Status live yang diverifikasi

- Anonymous Sign-Ins aktif (`anonymous_users: true`).
- Provider Google belum aktif (`google: false`); login Google masih memerlukan OAuth Client ID/Secret di dashboard, yang tidak boleh dikirim melalui chat.
- RPC `get_my_room` belum tersedia pada project live (`PGRST202`), jadi guest create/join dan multiplayer berbasis RPC belum dapat lulus uji live.
- Migrasi belum diterapkan. SQL Editor draft kosong dan tidak ada SQL parsial yang dijalankan.
- Browser menolak akses file lokal dan memblokir akses localhost untuk pemindahan teks SQL ke editor. Belum ada jalur aman untuk meneruskan berkas lokal ke SQL Editor.
- `npx --yes supabase --version` tersedia pada v2.120.0. `projects list` tidak menampilkan project ref runtime; `supabase link --project-ref ...` ditolak endpoint karena hak akun tidak mencukupi. `db push --dry-run` berhenti pada isu IPv6 sebelum koneksi database; folder project juga belum memiliki `config.toml`/project link dan tidak ada koneksi PostgreSQL.
- Tidak ada jalur migrasi CLI yang berhak mengakses project runtime. SQL Editor tetap dapat digunakan oleh pemilik akun dengan menempelkan `setup.sql` utuh.
- Endpoint `/setup.sql` production terverifikasi masih HTTP 200. Rute publik tersebut sudah dihapus dari `server.mjs`; build server lokal kini mengembalikan 404 untuk SQL, migration, dan `.env.local`. Production akan tetap menyajikan versi lama sampai deployment.

### Verifikasi terbaru

- `npm test -- --reporter=dot`: 12 tes lulus.
- `npm run lint`: lulus.
- `npm run build`: lulus; hanya peringatan anotasi PURE dari dependency Zod.
- `CHROME_PATH=... npm run test:e2e`: 2 tes lulus, dua browser context terpisah. Tes ini memverifikasi UI shell/mobile, bukan Auth atau Supabase live.
- Smoke server lama sebelum patch keamanan: `/healthz` dan `/setup.sql` HTTP 200. Nilai konfigurasi tidak dicetak.
- Smoke server setelah patch keamanan: `/healthz` HTTP 200; `/setup.sql`, `/supabase/migrations/...`, dan `/.env.local` HTTP 404.
- Supabase Auth settings live: `external.anonymous_users=true`, `external.google=false`.
- `npx supabase projects list`: lima project terlihat, tetapi project ref yang dipakai aplikasi tidak termasuk. Link ditolak karena privilege.
- Pemeriksaan `.env` saat ini dan dua revisi Git menunjukkan hanya URL serta publishable key dengan claim `role=anon`; tidak ditemukan assignment service-role/database password/Google secret maupun prefix secret key. `.env` lokal dipertahankan dan kini di-ignore/untrack.
- Uji Google OAuth, sesi Auth live, create/join, RLS live, RPC game, dan realtime dua akun masih `BLOCKED` sampai migration v2 diterapkan dan provider Google dikonfigurasi.
