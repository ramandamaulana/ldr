import { describe, expect, it } from 'vitest';
import { CATEGORIES, GAMES, QUESTION_BANK, gameRules, choosePrompt, questionRows } from './registry';

describe('question bank and mode registry', () => {
  it('keeps at least 20 ordered-depth prompts in every required category', () => {
    expect(CATEGORIES).toHaveLength(7);
    expect(CATEGORIES.every((category) => QUESTION_BANK[category].length >= 20)).toBe(true);
    expect(questionRows).toHaveLength(140);
    for (const category of CATEGORIES) {
      const depths = QUESTION_BANK[category].map((question) => question.d);
      expect(depths.every((depth) => depth >= 1 && depth <= 3)).toBe(true);
      expect(depths).toEqual([...depths].sort((a,b) => a-b));
    }
  });

  it('uses canonical game identifiers and filters selected prompts', () => {
    expect(GAMES.map((game) => game.id)).toContain('deep_talk');
    expect(GAMES).toHaveLength(10);
    const filtered = choosePrompt('deep_talk','🍕 Receh & Random',1,[]);
    expect(filtered.category).toBe('🍕 Receh & Random');
    expect(filtered.difficulty).toBe(1);
    expect(choosePrompt('deep_talk','🍕 Receh & Random',1,[filtered.id]).id).not.toBe(filtered.id);
  });

  it('detects wins and a completed draw in Tic-Tac-Toe', () => {
    expect(gameRules.winner(['❤️','❤️','❤️',null,null,null,null,null,null])).toBe('❤️');
    expect(gameRules.winner(['❤️','💙','❤️','❤️','💙','💙','💙','❤️','❤️'])).toBe('draw');
    expect(gameRules.winner(['❤️',null,null,null,null,null,null,null,null])).toBeNull();
  });
});
