import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const sql = await readFile(new URL('../setup.sql', import.meta.url), 'utf8');
const match = html.match(/\/\* GAME_RULES_START \*\/([\s\S]*?)\/\* GAME_RULES_END \*\//);
assert.ok(match, 'pure game rules block must exist in index.html');
const rules = vm.runInNewContext(`(()=>{${match[1]};return {validQuestionFor,selectQuestionFor,canTransitionGameSession,canActOnTurn,ticTacToeWinner,resolveSnakeMove,SNAKE_LADDERS,SNAKE_SLIDES}})()`);

test('question selection enforces game type, category, depth, and used IDs', () => {
  const rows = [
    { id: 'deep-a', game_type: 'deep', category: '🍕', prompt: 'deep one', difficulty: 1 },
    { id: 'guess-a', game_type: 'guess', category: '🍕', prompt: 'guess one', difficulty: 1 },
    { id: 'deep-b', game_type: 'deep', category: '🎬', prompt: 'deep two', difficulty: 2 },
  ];
  assert.equal(rules.validQuestionFor(rows[0], 'deep'), true);
  assert.equal(rules.validQuestionFor(rows[0], 'guess'), false);
  assert.equal(rules.selectQuestionFor(rows, 'deep', '🍕', 1, [], () => 0).id, 'deep-a');
  assert.equal(rules.selectQuestionFor(rows, 'deep', '🍕', 1, ['deep-a'], () => 0), null);
  assert.equal(rules.selectQuestionFor(rows, 'unknown', null, null), null);
});

test('session transitions reject skipped lifecycle states', () => {
  assert.equal(rules.canTransitionGameSession('ready', 'playing'), true);
  assert.equal(rules.canTransitionGameSession('waiting', 'finished'), false);
  assert.equal(rules.canTransitionGameSession('finished', 'playing'), true);
});

test('turn ownership compares normalized player slots', () => {
  assert.equal(rules.canActOnTurn('1', 1), true);
  assert.equal(rules.canActOnTurn(0, 1), false);
});

test('Tic-Tac-Toe detects lines, draws, and unfinished boards', () => {
  assert.equal(rules.ticTacToeWinner(['x','x','x','','','','','','']), 'x');
  assert.equal(rules.ticTacToeWinner(['o','','','','o','','','','o']), 'o');
  assert.equal(rules.ticTacToeWinner(['x','o','x','x','o','o','o','x','x']), 'draw');
  assert.equal(rules.ticTacToeWinner(['x','','','','','','','','']), null);
});

test('snake and ladder moves honor dice bounds and exact finish', () => {
  assert.throws(() => rules.resolveSnakeMove(1, 0), /Dadu harus 1–6/);
  assert.throws(() => rules.resolveSnakeMove(1, 7), /Dadu harus 1–6/);
  assert.deepEqual({ ...rules.resolveSnakeMove(3, 1) }, { from: 3, roll: 1, landed: 4, to: 14, tile: 'ladder', winner: false });
  assert.equal(rules.resolveSnakeMove(16, 1).to, 7);
  assert.equal(rules.resolveSnakeMove(99, 2).tile, 'overshoot');
  assert.equal(rules.resolveSnakeMove(94, 6).winner, true);
  assert.equal(rules.SNAKE_LADDERS[28], 84);
  assert.equal(rules.SNAKE_SLIDES[99], 78);
});

test('room SQL has private answer projection and serialized writes', () => {
  const getRoom = sql.match(/create or replace function public\.get_ldr_room[\s\S]*?end \$\$;/)?.[0] ?? '';
  const saveRoom = sql.match(/create or replace function public\.save_ldr_room[\s\S]*?end \$\$;/)?.[0] ?? '';
  assert.match(getRoom, /player_slot<>owner_slot/);
  assert.match(getRoom, /answers_view:=answers_view-owner_slot::text/);
  assert.match(getRoom, /if ready then/);
  assert.match(saveRoom, /for update/);
  assert.match(saveRoom, /gameSession/);
  assert.match(saveRoom, /players/);
});
