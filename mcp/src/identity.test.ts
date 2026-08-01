import { describe, expect, it } from 'vitest';

import { isAllowed, parseAllowlist } from './identity';

describe('許可リスト', () => {
  it('カンマ区切りを読み、前後の空白を落とす', () => {
    const list = parseAllowlist(' a@example.com , b@example.com ');
    expect(list.has('a@example.com')).toBe(true);
    expect(list.has('b@example.com')).toBe(true);
    expect(list.size).toBe(2);
  });

  it('大文字小文字を区別しない', () => {
    const list = parseAllowlist('Alice@Example.COM');
    expect(isAllowed(list, 'alice@example.com')).toBe(true);
    expect(isAllowed(list, 'ALICE@EXAMPLE.COM')).toBe(true);
  });

  it('リストに無いアカウントは拒否する', () => {
    const list = parseAllowlist('a@example.com');
    expect(isAllowed(list, 'b@example.com')).toBe(false);
  });

  it('空の許可リストは「全員拒否」であって「全員許可」ではない', () => {
    // 設定漏れで全世界に健康データが開くほうが、繋がらないより事故として重い
    expect(isAllowed(parseAllowlist(''), 'a@example.com')).toBe(false);
    expect(isAllowed(parseAllowlist(undefined), 'a@example.com')).toBe(false);
  });

  it('空要素を無視する', () => {
    expect(parseAllowlist('a@example.com,,').size).toBe(1);
  });
});
