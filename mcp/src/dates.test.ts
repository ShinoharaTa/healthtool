import { describe, expect, it, vi } from 'vitest';

import { daysBetween, MAX_RANGE_DAYS, resolveRange, shiftDays, todayIn } from './dates';

describe('日付の計算', () => {
  it('日をずらす', () => {
    expect(shiftDays('2026-08-01', -1)).toBe('2026-07-31');
    expect(shiftDays('2026-02-28', 1)).toBe('2026-03-01');
  });

  it('両端を含めて日数を数える', () => {
    expect(daysBetween('2026-08-01', '2026-08-01')).toBe(1);
    expect(daysBetween('2026-07-30', '2026-08-01')).toBe(3);
  });

  it('タイムゾーンによって「今日」が変わる', () => {
    // UTC で 8/1 15:30 は、日本時間ではすでに 8/2
    vi.setSystemTime(new Date('2026-08-01T15:30:00Z'));
    expect(todayIn('UTC')).toBe('2026-08-01');
    expect(todayIn('Asia/Tokyo')).toBe('2026-08-02');
    vi.useRealTimers();
  });
});

describe('期間の解決', () => {
  it('未指定なら今日を終端に既定日数ぶん遡る', () => {
    vi.setSystemTime(new Date('2026-08-01T03:00:00Z'));
    expect(resolveRange({}, 'Asia/Tokyo', 28)).toEqual({
      from: '2026-07-05',
      to: '2026-08-01',
    });
    vi.useRealTimers();
  });

  it('to だけ指定すればそこから遡る', () => {
    expect(resolveRange({ to: '2026-07-31' }, 'Asia/Tokyo', 7)).toEqual({
      from: '2026-07-25',
      to: '2026-07-31',
    });
  });

  it('両方指定すればそのまま使う', () => {
    expect(resolveRange({ from: '2026-01-01', to: '2026-01-31' }, 'UTC', 28)).toEqual({
      from: '2026-01-01',
      to: '2026-01-31',
    });
  });

  it('形式が違えば、何が悪いか分かる例外を出す', () => {
    expect(() => resolveRange({ from: '2026/01/01' }, 'UTC', 7)).toThrow(/yyyy-MM-dd/);
    expect(() => resolveRange({ to: '8月1日' }, 'UTC', 7)).toThrow(/yyyy-MM-dd/);
  });

  it('逆転した期間を拒否する', () => {
    expect(() => resolveRange({ from: '2026-08-01', to: '2026-07-01' }, 'UTC', 7)).toThrow(
      /逆転/,
    );
  });

  it('長すぎる期間を拒否する', () => {
    // 黙って切り詰めると、モデルは全期間を見たつもりで結論を出してしまう
    const from = shiftDays('2026-08-01', -MAX_RANGE_DAYS);
    expect(() => resolveRange({ from, to: '2026-08-01' }, 'UTC', 7)).toThrow(/日まで/);
  });

  it('上限ちょうどは通す', () => {
    const from = shiftDays('2026-08-01', -(MAX_RANGE_DAYS - 1));
    expect(() => resolveRange({ from, to: '2026-08-01' }, 'UTC', 7)).not.toThrow();
  });
});
