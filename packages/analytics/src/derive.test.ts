import type { DailySummary } from '@healthtool/schema';
import { describe, expect, it } from 'vitest';

import { buildTrendReport, enumerateDates } from './derive';

/** テスト用の日次サマリーを組み立てる。指定しなかった指標は欠損になる。 */
function day(
  date: string,
  v: {
    steps?: number;
    exerciseMin?: number;
    sleepMin?: number;
    deepMin?: number;
    efficiency?: number;
    restingBpm?: number;
    midSleep?: string;
    wornHours?: number;
  } = {},
): DailySummary {
  return {
    schemaVersion: 1,
    date,
    tz: 'Asia/Tokyo',
    activity:
      v.steps !== undefined || v.exerciseMin !== undefined
        ? { steps: v.steps ?? null, exerciseMin: v.exerciseMin ?? null }
        : null,
    hr: v.restingBpm !== undefined ? { restingBpm: v.restingBpm } : null,
    sleep:
      v.sleepMin !== undefined || v.midSleep !== undefined
        ? {
            sessionIds: [],
            totalMin: v.sleepMin ?? null,
            deepMin: v.deepMin ?? null,
            efficiencyPct: v.efficiency ?? null,
            midSleepAt: v.midSleep ? `${date}T${v.midSleep}:00+09:00` : null,
          }
        : null,
    sources: ['com.mi.health'],
    coverage: {
      hrCoveredMin: (v.wornHours ?? 20) * 60,
      wornHours: v.wornHours ?? 20,
      hasSleep: v.sleepMin !== undefined,
      hasSteps: v.steps !== undefined,
    },
    updatedAt: `${date}T12:00:00+09:00`,
  } as DailySummary;
}

describe('日付の列挙', () => {
  it('両端を含む', () => {
    expect(enumerateDates('2026-07-30', '2026-08-01')).toEqual([
      '2026-07-30',
      '2026-07-31',
      '2026-08-01',
    ]);
  });

  it('月をまたいでも正しい', () => {
    expect(enumerateDates('2026-02-27', '2026-03-01')).toEqual([
      '2026-02-27',
      '2026-02-28',
      '2026-03-01',
    ]);
  });

  it('逆転した期間は例外', () => {
    expect(() => enumerateDates('2026-08-01', '2026-07-01')).toThrow();
  });
});

describe('指標の要約', () => {
  const dates = enumerateDates('2026-07-03', '2026-08-01'); // 30日
  const dailies = dates.map((d, i) => day(d, { steps: 8000 + i * 100, restingBpm: 60 }));

  const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });
  const steps = report.metrics.find((m) => m.key === 'activity.steps')!;

  it('欠損日を要求期間から数える', () => {
    expect(report.period.daysRequested).toBe(30);
    expect(steps.n).toBe(30);
    expect(steps.missing).toBe(0);
  });

  it('最新値は最後に値があった日を指す', () => {
    expect(steps.latest).toEqual({ date: '2026-08-01', value: 10900 });
  });

  it('直近7日と前7日の差を出す', () => {
    // 1日100歩ずつ増えるので、7日平均の差は 700
    expect(steps.deltaVsPrev7).toBeCloseTo(700, 6);
  });

  it('傾きは1日あたりの変化量', () => {
    expect(steps.trendPerDay).toBeCloseTo(100, 3);
  });

  it('取得できなかった指標は n=0 として残す（黙って消さない）', () => {
    const spo2 = report.metrics.find((m) => m.key === 'spo2.avgPct')!;
    expect(spo2.n).toBe(0);
    expect(spo2.missing).toBe(30);
    expect(spo2.latest).toBeNull();
    expect(report.coverage.neverAvailable).toContain('spo2.avgPct');
  });

  it('指標の良し悪しの向きを明示する', () => {
    expect(steps.direction).toBe('higher-is-better');
    expect(report.metrics.find((m) => m.key === 'hr.restingBpm')!.direction).toBe(
      'lower-is-better',
    );
  });
});

describe('欠損日の扱い', () => {
  it('データが無い日を欠損として数え、平均の分母に入れない', () => {
    // 10日間のうち5日だけデータがある
    const dailies = ['2026-07-23', '2026-07-25', '2026-07-27', '2026-07-29', '2026-07-31'].map(
      (d) => day(d, { steps: 10000 }),
    );
    const report = buildTrendReport(dailies, { from: '2026-07-23', to: '2026-08-01' });
    const steps = report.metrics.find((m) => m.key === 'activity.steps')!;

    expect(report.coverage.daysRequested).toBe(10);
    expect(report.coverage.daysWithAnyData).toBe(5);
    expect(steps.n).toBe(5);
    expect(steps.missing).toBe(5);
    // 欠損を 0 歩として扱えば 5000 になってしまう
    expect(steps.mean).toBe(10000);
  });

  it('欠損が多い期間には注意書きを付ける', () => {
    const dailies = [day('2026-07-31', { steps: 1000 })];
    const report = buildTrendReport(dailies, { from: '2026-07-23', to: '2026-08-01' });
    expect(report.caveats.join('\n')).toMatch(/しかデータがありません/);
    expect(report.caveats.join('\n')).toMatch(/2 週間未満/);
  });

  it('装着時間が短い日を数えて警告する', () => {
    const dates = enumerateDates('2026-07-03', '2026-08-01');
    const dailies = dates.map((d, i) => day(d, { steps: 5000, wornHours: i < 4 ? 3 : 22 }));
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });

    expect(report.coverage.lowWearDays).toBe(4);
    expect(report.caveats.join('\n')).toMatch(/装着時間/);
  });

  it('データが皆無なら、その事実だけを返す', () => {
    const report = buildTrendReport([], { from: '2026-07-23', to: '2026-08-01' });
    expect(report.coverage.daysWithAnyData).toBe(0);
    expect(report.caveats[0]).toMatch(/1 日もありません/);
  });
});

describe('遅れ相関', () => {
  const dates = enumerateDates('2026-07-03', '2026-08-01'); // 30日

  it('歩数と「翌日の」睡眠を突き合わせる', () => {
    // 歩数を 1 日ずらして睡眠に反映させた合成データ。
    // lag=1 で見れば強い相関、lag=0 では相関しないはず。
    const stepPattern = dates.map((_, i) => 4000 + ((i * 1700) % 9000));
    const dailies = dates.map((d, i) =>
      day(d, {
        steps: stepPattern[i]!,
        // i 日目の睡眠は i-1 日目の歩数で決まる
        sleepMin: i === 0 ? 400 : 300 + stepPattern[i - 1]! / 100,
      }),
    );

    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });
    const lagged = report.correlations.find(
      (c) => c.x === 'activity.steps' && c.y === 'sleep.totalMin',
    )!;

    expect(lagged.lagDays).toBe(1);
    expect(lagged.r).toBeGreaterThan(0.95);
    expect(lagged.n).toBe(29);
  });

  it('同日どうしの相関は lag=0 で扱う', () => {
    const dailies = dates.map((d, i) =>
      day(d, { sleepMin: 300 + i * 5, restingBpm: 70 - i * 0.3 }),
    );
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });
    const c = report.correlations.find(
      (x) => x.x === 'sleep.totalMin' && x.y === 'hr.restingBpm',
    )!;

    expect(c.lagDays).toBe(0);
    expect(c.r).toBeCloseTo(-1, 2);
    expect(c.n).toBe(30);
  });

  it('データが足りない相関は r=null のまま n を返す', () => {
    const dailies = [day('2026-07-31', { steps: 100, sleepMin: 400 })];
    const report = buildTrendReport(dailies, { from: '2026-07-23', to: '2026-08-01' });
    for (const c of report.correlations) {
      expect(c.r).toBeNull();
    }
  });
});

describe('就寝リズム', () => {
  const dates = enumerateDates('2026-07-03', '2026-08-01');

  it('毎日ほぼ同じ時刻に寝ていればばらつきが小さい', () => {
    const dailies = dates.map((d, i) =>
      day(d, { sleepMin: 420, midSleep: i % 2 === 0 ? '03:00' : '03:10' }),
    );
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });

    expect(report.sleepRegularity.meanMidSleep).toBe('03:05');
    expect(report.sleepRegularity.midSleepStdevMin!).toBeLessThan(10);
    expect(report.sleepRegularity.n).toBe(30);
  });

  it('0時をまたぐ就寝でも中点を正しく出す', () => {
    const dailies = dates.map((d, i) =>
      day(d, { sleepMin: 420, midSleep: i % 2 === 0 ? '23:50' : '00:10' }),
    );
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });

    expect(report.sleepRegularity.meanMidSleep).toBe('00:00');
    // 線形の標準偏差なら 12 時間近くになるところ
    expect(report.sleepRegularity.midSleepStdevMin!).toBeLessThan(30);
  });

  it('休日に寝る時刻がずれる分を social jetlag として出す', () => {
    // 平日は 03:00、土日は 05:00 に寝る
    const dailies = dates.map((d) => {
      const dow = new Date(`${d}T00:00:00Z`).getUTCDay();
      const weekend = dow === 0 || dow === 6;
      return day(d, { sleepMin: 420, midSleep: weekend ? '05:00' : '03:00' });
    });
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });

    expect(report.sleepRegularity.socialJetlagMin).toBeCloseTo(120, 0);
  });
});

describe('平日と休日', () => {
  it('平日と休日の平均差を出す', () => {
    const dates = enumerateDates('2026-07-03', '2026-08-01');
    const dailies = dates.map((d) => {
      const dow = new Date(`${d}T00:00:00Z`).getUTCDay();
      const weekend = dow === 0 || dow === 6;
      return day(d, { steps: weekend ? 3000 : 9000 });
    });
    const report = buildTrendReport(dailies, { from: '2026-07-03', to: '2026-08-01' });
    const split = report.weekdayWeekend.find((s) => s.key === 'activity.steps')!;

    expect(split.weekday).toBe(9000);
    expect(split.weekend).toBe(3000);
    expect(split.diff).toBe(-6000);
  });
});

describe('メタ情報', () => {
  it('タイムゾーンを記録する', () => {
    const report = buildTrendReport([day('2026-08-01', { steps: 100 })], {
      from: '2026-08-01',
      to: '2026-08-01',
    });
    expect(report.timezone).toBe('Asia/Tokyo');
  });

  it('入力の順序が乱れていても日付順に処理する', () => {
    const dailies = [
      day('2026-08-01', { steps: 300 }),
      day('2026-07-30', { steps: 100 }),
      day('2026-07-31', { steps: 200 }),
    ];
    const report = buildTrendReport(dailies, { from: '2026-07-30', to: '2026-08-01' });
    const steps = report.metrics.find((m) => m.key === 'activity.steps')!;

    expect(steps.latest).toEqual({ date: '2026-08-01', value: 300 });
    expect(steps.trendPerDay).toBeCloseTo(100, 6);
  });
});
