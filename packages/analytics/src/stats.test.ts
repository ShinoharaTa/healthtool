import { describe, expect, it } from 'vitest';

import {
  circularStats,
  compact,
  mean,
  pearson,
  rollingMean,
  slopePerDay,
  stdev,
} from './stats';

describe('欠損の扱い', () => {
  it('null と undefined と NaN を落とし、0 に潰さない', () => {
    expect(compact([1, null, 2, undefined, NaN, 3])).toEqual([1, 2, 3]);
  });

  it('平均は欠損を分母に数えない', () => {
    // 0 として扱うと 1.5 になってしまう
    expect(mean([1, null, 2, null])).toBe(1.5);
    expect(mean([3, 3, 3])).toBe(3);
  });

  it('すべて欠損なら null', () => {
    expect(mean([null, undefined])).toBeNull();
    expect(stdev([null])).toBeNull();
  });

  it('標準偏差は 1 点では定義しない', () => {
    expect(stdev([5])).toBeNull();
    expect(stdev([2, 4])).toBeCloseTo(1.414, 3);
  });
});

describe('移動平均', () => {
  it('後方 window で、その位置を含めて平均する', () => {
    const out = rollingMean([1, 2, 3, 4, 5], 3, 1);
    expect(out[0]).toBe(1);
    expect(out[1]).toBe(1.5);
    expect(out[2]).toBe(2);
    expect(out[4]).toBe(4);
  });

  it('窓の中の有効点が minSamples 未満なら null を返す', () => {
    // 欠損だらけの窓から出した値を「7日平均」と称さないための保護
    const out = rollingMean([10, null, null, null, null, null, null], 7, 4);
    expect(out[6]).toBeNull();
  });

  it('十分な点が揃えば値を返す', () => {
    const out = rollingMean([1, 2, 3, 4, null, null, null], 7, 4);
    expect(out[6]).toBe(2.5);
  });
});

describe('相関', () => {
  it('完全な正の相関で r=1', () => {
    const r = pearson([1, 2, 3, 4, 5, 6, 7, 8], [2, 4, 6, 8, 10, 12, 14, 16]);
    expect(r?.r).toBeCloseTo(1, 10);
    expect(r?.n).toBe(8);
  });

  it('完全な負の相関で r=-1', () => {
    const r = pearson([1, 2, 3, 4, 5, 6, 7, 8], [8, 7, 6, 5, 4, 3, 2, 1]);
    expect(r?.r).toBeCloseTo(-1, 10);
  });

  it('片方が欠損している日は組から外す', () => {
    const r = pearson(
      [1, 2, null, 3, 4, 5, 6, 7, 8],
      [2, 4, 100, 6, 8, 10, 12, 14, 16],
    );
    expect(r?.n).toBe(8);
    expect(r?.r).toBeCloseTo(1, 10);
  });

  it('組が少なすぎるときは null（偶然と区別できないため）', () => {
    expect(pearson([1, 2, 3], [1, 2, 3])).toBeNull();
  });

  it('片方が定数なら相関は定義しない', () => {
    expect(pearson([1, 2, 3, 4, 5, 6, 7, 8], [5, 5, 5, 5, 5, 5, 5, 5])).toBeNull();
  });

  it('長さが違えば例外', () => {
    expect(() => pearson([1, 2], [1])).toThrow();
  });
});

describe('傾き', () => {
  it('1日あたりの変化量を返す', () => {
    expect(slopePerDay([10, 12, 14, 16])).toBeCloseTo(2, 10);
  });

  it('欠損日があっても日インデックスの間隔を保つ', () => {
    // 0日目=10, 2日目=14 → 傾きは 2/日。欠損を詰めて 4/日 にしてはいけない
    expect(slopePerDay([10, null, 14, null, 18])).toBeCloseTo(2, 10);
  });
});

describe('円周統計（就寝時刻）', () => {
  const at = (h: number, m = 0) => h * 60 + m;

  it('0時をまたぐ時刻の平均を正しく出す', () => {
    // 23:50 と 00:10 の平均は 00:00 であって 12:00 ではない
    const s = circularStats([at(23, 50), at(0, 10)]);
    expect(s).not.toBeNull();
    expect(s!.meanMinutes).toBeCloseTo(0, 1);
  });

  it('普通の時間帯でも通常の平均と一致する', () => {
    const s = circularStats([at(3, 0), at(4, 0), at(5, 0)]);
    expect(s!.meanMinutes).toBeCloseTo(at(4, 0), 1);
  });

  it('毎日同じ時刻ならばらつきは 0', () => {
    const s = circularStats([at(3, 0), at(3, 0), at(3, 0), at(3, 0)]);
    expect(s!.stdevMinutes).toBeCloseTo(0, 6);
  });

  it('就寝時刻がばらつくほど標準偏差が大きくなる', () => {
    const tight = circularStats([at(3, 0), at(3, 15), at(2, 45), at(3, 5)])!;
    const loose = circularStats([at(1, 0), at(5, 0), at(2, 0), at(6, 0)])!;
    expect(loose.stdevMinutes).toBeGreaterThan(tight.stdevMinutes);
  });

  it('0時またぎでもばらつきを過大評価しない', () => {
    // 23:30 と 00:30 の実際の差は 1 時間。線形の標準偏差なら約 12 時間分になってしまう
    const s = circularStats([at(23, 30), at(0, 30), at(23, 45), at(0, 15)])!;
    expect(s.stdevMinutes).toBeLessThan(60);
  });

  it('1 点以下では定義しない', () => {
    expect(circularStats([at(3, 0)])).toBeNull();
    expect(circularStats([null, undefined])).toBeNull();
  });
});
