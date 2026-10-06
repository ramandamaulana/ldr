import questions from './questions.json';
import type { GameType } from '../../types/room';

export const AVATARS = ['🐻','🐼','🐰','🦊','🐱','🐸','🐣','🦋','🦦','🐨','🐹','🐧'] as const;
export const LEVELS = ['Baru Kenalan','Mulai Nyaman','Teman Cerita','Satu Frekuensi','Teman Pulang','Jarak Bukan Masalah','Tim Andalan','Peta Kenangan','Teman Bertumbuh','Rumah Kedua','Partner Kompak','Penuh Cerita','Saling Mengerti','Duo Favorit','Teman Seumur Cerita','Makin Dekat','Banyak Kenangan','Selalu Satu Tim','Cinta dan Tawa','Soulmate'];
export const CATEGORIES = Object.keys(questions);
export const QUESTION_BANK = questions as unknown as Record<string, { q: string; d: number }[]>;
export const questionRows = CATEGORIES.flatMap((category) => QUESTION_BANK[category].map(({q:prompt,d:difficulty}, index) => ({ id: `${category}-${index}`, category, prompt, difficulty })));

export const GAMES: { id: GameType; icon: string; title: string; description: string }[] = [
  { id: 'guess_me', icon: '🕵️', title: 'Tebak Aku', description: 'Satu jawab rahasia, satunya coba nebak.' },
  { id: 'would_you_rather', icon: '🤔', title: 'Would You Rather', description: 'Pilih diam-diam, lihat sefrekuensi apa.' },
  { id: 'deep_talk', icon: '💬', title: 'Deep Talk Ringan', description: 'Kartu obrolan, jawab kapan saja.' },
  { id: 'hot_takes', icon: '🌶️', title: 'Hot Takes', description: 'Voting receh lanjut debat tipis-tipis.' },
  { id: 'ldr_challenge', icon: '🎯', title: 'Tantangan LDR', description: 'Misi kecil, bukti bisa dikirim di chat.' },
  { id: 'couple_quiz', icon: '🧠', title: 'Kuis Kita', description: 'Pertanyaan tentang cerita kalian.' },
  { id: 'dream_date', icon: '🗺️', title: 'Dream Date Planner', description: 'Rancang kencan impian bareng-bareng.' },
  { id: 'story_chain', icon: '📖', title: 'Cerita Bersambung', description: 'Satu kalimat aja, plot makin liar.' },
  { id: 'tic_tac_toe', icon: '⭕', title: 'Tic-Tac-Toe', description: 'Duel kecil, giliran dijaga server.' },
  { id: 'snakes_ladders', icon: '🐍', title: 'Ular Tangga', description: 'Dadu server, tangga bikin senang.' },
];

export const WYR = [
  ['Seumur hidup cuma bisa kirim voice note 🎙️','atau cuma bisa kirim stiker 🐸'],
  ['Kencan di toko buku 📚','atau piknik di ruang tamu 🧺'],
  ['Selalu telat 10 menit ⏰','atau datang 1 jam terlalu awal ☕'],
  ['Telepon sambil masak 🍳','atau nonton bareng sambil ngemil 🍿'],
  ['Liburan tanpa itinerary 🗺️','atau itinerary sampai menitnya 📋'],
  ['Bisa baca pikiran pasangan 🤯','atau selalu tahu camilan yang dia mau 🍟'],
];
export const HOT_TAKES = ['Bubur diaduk atau nggak diaduk?','Nanas di pizza: masuk akal atau kriminal?','Mie kuah pakai nasi: iya atau tidak?','Tidur pakai kaus kaki: nyaman atau aneh?','Pancake lebih enak daripada waffle?','Sereal dulu atau susu dulu?','Film bagus boleh ditonton sambil scroll HP?','Mandi pagi atau mandi malam?'];
export const CHALLENGES = ['Kirim foto langit yang kamu lihat hari ini ☁️','Bikin pantun 2 baris buat pasanganmu ✍️','Kirim selfie dengan ekspresi paling absurd 🤪','Nyanyikan 10 detik lagu pilihan pasanganmu 🎤','Pilih menu sama, masak atau pesan, lalu bandingkan 🍜','Kirim emoji paling aneh yang bisa kamu temukan 👾'];
export const MINI_EVENTS = ['Hari ini wajib kirim emoji paling aneh yang kalian punya 👾','Kirim satu pujian spesifik, jangan cuma “kamu baik” 💌','Pilih lagu yang jadi soundtrack hari ini 🎧','Kirim foto langit dari tempat kalian masing-masing ☁️','Tanya pasangan: camilan apa yang paling dibutuhkan sekarang? 🍪'];

export function choosePrompt(game: GameType, category: string, depth: number, used: string[] = []) {
  let rows = questionRows.filter((row) => !used.includes(row.id) && row.difficulty <= depth && (category === 'Semua kategori' || row.category === category));
  if (!rows.length) rows = questionRows.filter((row) => !used.includes(row.id));
  if (!rows.length) rows = questionRows;
  if (game === 'couple_quiz') rows = rows.filter((row) => row.category === '💭 Kenangan' || row.category === '💞 Kita Berdua');
  return rows[Math.floor(Math.random() * rows.length)]!;
}

export const gameRules = {
  winner(board: (string|null)[]) {
    const lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];
    for (const [a,b,c] of lines) if (board[a] && board[a] === board[b] && board[b] === board[c]) return board[a];
    return board.every(Boolean) ? 'draw' : null;
  },
};
