# Jauh Dekat 💌

Game obrolan pasangan LDR yang mobile-first. UI dan bank pertanyaan berada dalam satu file `index.html`. Server Node kecil membaca `.env.local` dan menyediakan konfigurasi Supabase ke halaman; `setup.sql` membuat room dua kursi dengan kode acak enam karakter dan token sesi pribadi per pemain.

## Main di dua HP

1. Buka [Supabase Dashboard](https://supabase.com/dashboard), masuk/daftar, lalu buat project baru.
2. Buka **SQL Editor → New query**, salin seluruh isi `setup.sql`, tempel, lalu tekan **Run**.
3. Salin `.env.example` menjadi `.env.local`. Isi `SUPABASE_URL` dan `SUPABASE_PUBLISHABLE_KEY` dari dialog **Connect** atau **Settings → API Keys**. Key `anon` lama bisa dipakai dengan nama `SUPABASE_ANON_KEY`. Jangan gunakan `secret` atau `service_role` key. Lihat [panduan resmi API Keys](https://supabase.com/docs/guides/getting-started/api-keys).
4. Jalankan server lokal dari folder ini:

   ```bash
   npm start
   ```

   Buka `http://localhost:3000`. Status di kartu awal akan menunjukkan **Supabase siap terhubung** jika file env sudah terisi.
5. Untuk main dari dua HP yang berjauhan, deploy folder ini ke hosting yang bisa menjalankan Node.js. Atur `SUPABASE_URL` dan `SUPABASE_PUBLISHABLE_KEY` di bagian Environment Variables hosting tersebut, lalu bagikan URL situsnya. Jangan deploy `.env.local`. Setelah mengubah `setup.sql`, jalankan ulang seluruh file di SQL Editor sebelum deploy versi aplikasi yang baru.
6. Pemain pertama pilih nama/avatar lalu **Buat room**. Bagikan kode enam karakter ke pasangan. Pemain kedua masukkan nama/avatar dan kode lalu pilih **Gabung pakai kode**.

> Room menerima maksimal dua kursi. Kode saja belum cukup untuk membaca/menulis room setelah bergabung: setiap perangkat juga menyimpan token sesi acak. Jangan bagikan kode secara publik. Untuk demo tanpa setup backend, pilih **Coba demo**; demo disimpan lokal dan tidak tersinkron ke HP lain.

## Cara main

Pilih salah satu mode obrolan, kreatif, atau mini-game. Tombol sinkron/asinkron mengatur tempo bermain; jawaban, progres, XP, streak, album, dan Memory Jar tersimpan di room. Koneksi room diperbarui otomatis tiap beberapa detik. Browser menyimpan token untuk lanjut setelah ditutup dan dibuka lagi.

Mode Generate pertanyaan menyiapkan prompt sesuai kategori dan mood untuk disalin ke AI pilihanmu; versi ini tidak mengirim data ke layanan AI.

## Menambah pertanyaan

Buka `index.html`, cari komentar `Bank pertanyaan dipisah di sini`, lalu tambahkan item ke array kategori dengan format:

```js
['Pertanyaan baru kamu?', 1]
```

Angka kedalaman: `1` ringan, `2` sedang, `3` dalam. Kategori **Deep** bisa dimatikan dari pengaturan room.

## Catatan versi pertama

- Satu file HTML untuk UI; `server.mjs` membaca env dan `setup.sql` menyiapkan room bersama.
- Tautan Supabase JS dan font dimuat dari CDN, sehingga koneksi internet dibutuhkan.
- Voice note/foto dikirim melalui aplikasi chat pilihan kalian; game menyediakan kolom catatan/tautan, bukan penyimpanan media.
- Backend memakai polling berkala, bukan koneksi real-time push.
- Jalankan `npm test` untuk tes aturan seleksi pertanyaan, transisi sesi, giliran, Tic-Tac-Toe, dan Ular Tangga.
