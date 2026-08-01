import type { DailySummary } from '@healthtool/schema';

import { METRICS, type MetricDef } from './metrics';
import {
  circularStats,
  compact,
  maxOf,
  mean,
  median,
  minOf,
  pearson,
  rollingMean,
  round,
  slopePerDay,
  stdev,
  type Correlation,
} from './stats';

/** 1 指標の要約。LLM はここの数値をそのまま引用できる。 */
export interface MetricSummary {
  key: string;
  label: string;
  unit: string;
  direction: MetricDef['direction'];
  /** 値があった日数。 */
  n: number;
  /** 期間内で値が無かった日数。 */
  missing: number;
  latest: { date: string; value: number } | null;
  mean7: number | null;
  mean28: number | null;
  /** 直近7日平均 − その前の7日平均。改善/悪化の判断はここを見る。 */
  deltaVsPrev7: number | null;
  /** 期間全体の平均・中央値・最小・最大。 */
  mean: number | null;
  median: number | null;
  min: number | null;
  max: number | null;
  stdev: number | null;
  /** 1日あたりの変化量（最小二乗）。 */
  trendPerDay: number | null;
}

/** 就寝リズムの安定度。 */
export interface SleepRegularity {
  /** 睡眠中点の円周平均（HH:MM 表記）。 */
  meanMidSleep: string | null;
  /**
   * 睡眠中点の円周標準偏差（分）。就寝リズムのばらつき。
   * 小さいほど毎日同じ時間帯に寝ている。
   */
  midSleepStdevMin: number | null;
  n: number;
  /** 平日と休日の睡眠中点の差（分）。social jetlag の目安。 */
  socialJetlagMin: number | null;
}

/** 平日と休日の比較。 */
export interface WeekdayWeekendSplit {
  key: string;
  label: string;
  unit: string;
  weekday: number | null;
  weekend: number | null;
  diff: number | null;
}

/** 遅れを明示した相関。 */
export interface CorrelationResult {
  x: string;
  y: string;
  /** y を何日ずらしたか。1 なら「x の翌日の y」。 */
  lagDays: number;
  description: string;
  r: number | null;
  n: number;
}

export interface CoverageReport {
  daysRequested: number;
  daysWithAnyData: number;
  avgWornHours: number | null;
  /** 装着時間が 12 時間未満だった日数。この日の指標は信頼度を下げるべき。 */
  lowWearDays: number;
  /** 指標ごとの取得日数。取得できていない指標を LLM に明示するため。 */
  availability: { key: string; label: string; present: number; missing: number }[];
  /** 一度も取得できなかった指標のキー。 */
  neverAvailable: string[];
}

export interface TrendReport {
  period: { from: string; to: string; daysRequested: number };
  timezone: string | null;
  coverage: CoverageReport;
  metrics: MetricSummary[];
  sleepRegularity: SleepRegularity;
  weekdayWeekend: WeekdayWeekendSplit[];
  correlations: CorrelationResult[];
  /** 解釈上の注意。LLM が確信度を調整するための材料。 */
  caveats: string[];
}

/** 装着時間がこれ未満の日は指標の信頼度が落ちる。 */
const LOW_WEAR_HOURS = 12;

/**
 * 日次サマリーから派生統計を組み立てる。
 *
 * 生の daily を 90 日分そのまま LLM に渡すと、傾向の抽出をモデル側の
 * 暗算に任せることになり、数字の取り違えが起きる。ここで機械的に確定させ、
 * モデルには「何が起きているかの解釈」だけをさせる。
 *
 * @param dailies 日付の昇順に並んだ日次サマリー。欠損日は含まれていなくてよい。
 * @param range 期間。欠損日を数えるために、実データではなく要求範囲を渡す。
 */
export function buildTrendReport(
  dailies: readonly DailySummary[],
  range: { from: string; to: string },
): TrendReport {
  const sorted = [...dailies].sort((a, b) => a.date.localeCompare(b.date));
  const allDates = enumerateDates(range.from, range.to);

  // 欠損日を null で埋めた密な系列にする。移動平均と相関の位置合わせに必要。
  const byDate = new Map(sorted.map((d) => [d.date, d]));
  const dense: (DailySummary | null)[] = allDates.map((d) => byDate.get(d) ?? null);

  const metrics = METRICS.map((def) => summarize(def, allDates, dense));

  return {
    period: { from: range.from, to: range.to, daysRequested: allDates.length },
    timezone: sorted[0]?.tz ?? null,
    coverage: buildCoverage(allDates, dense, metrics),
    metrics,
    sleepRegularity: buildRegularity(allDates, dense),
    weekdayWeekend: buildWeekdayWeekend(allDates, dense),
    correlations: buildCorrelations(allDates, dense),
    caveats: buildCaveats(allDates, dense, metrics),
  };
}

// ------------------------------------------------------------------ 指標要約

function summarize(
  def: MetricDef,
  dates: string[],
  dense: (DailySummary | null)[],
): MetricSummary {
  const series = dense.map((d) => (d ? def.get(d) ?? null : null));
  const present = compact(series);

  const roll7 = rollingMean(series, 7);
  const roll28 = rollingMean(series, 28, 14);

  // 直近7日とその前7日。両方に十分な点が無ければ差分は出さない。
  const last7 = series.slice(-7);
  const prev7 = series.slice(-14, -7);
  const m1 = compact(last7).length >= 3 ? mean(last7) : null;
  const m0 = compact(prev7).length >= 3 ? mean(prev7) : null;

  let latest: { date: string; value: number } | null = null;
  for (let i = series.length - 1; i >= 0; i--) {
    const v = series[i];
    if (typeof v === 'number' && Number.isFinite(v)) {
      latest = { date: dates[i]!, value: round(v)! };
      break;
    }
  }

  return {
    key: def.key,
    label: def.label,
    unit: def.unit,
    direction: def.direction,
    n: present.length,
    missing: series.length - present.length,
    latest,
    mean7: round(roll7[roll7.length - 1] ?? null),
    mean28: round(roll28[roll28.length - 1] ?? null),
    deltaVsPrev7: m1 !== null && m0 !== null ? round(m1 - m0) : null,
    mean: round(mean(series)),
    median: round(median(series)),
    min: round(minOf(series)),
    max: round(maxOf(series)),
    stdev: round(stdev(series)),
    trendPerDay: round(slopePerDay(series), 4),
  };
}

// -------------------------------------------------------------------- 欠損

function buildCoverage(
  dates: string[],
  dense: (DailySummary | null)[],
  metrics: MetricSummary[],
): CoverageReport {
  const worn = dense.map((d) => d?.coverage?.wornHours ?? null);

  return {
    daysRequested: dates.length,
    daysWithAnyData: dense.filter((d) => d !== null).length,
    avgWornHours: round(mean(worn)),
    lowWearDays: compact(worn).filter((h) => h < LOW_WEAR_HOURS).length,
    availability: metrics.map((m) => ({
      key: m.key,
      label: m.label,
      present: m.n,
      missing: m.missing,
    })),
    neverAvailable: metrics.filter((m) => m.n === 0).map((m) => m.key),
  };
}

// ------------------------------------------------------------ 就寝リズム

function buildRegularity(
  dates: string[],
  dense: (DailySummary | null)[],
): SleepRegularity {
  const midSleep = dense.map((d) => minutesOfDay(d?.sleep?.midSleepAt ?? null));
  const stats = circularStats(midSleep);

  // 平日と休日で睡眠中点がどれだけずれるか。
  // 円周平均どうしの差なので、0時をまたいでも正しく出る。
  const weekdayMid = circularStats(
    midSleep.filter((_, i) => !isWeekend(dates[i]!)),
  );
  const weekendMid = circularStats(
    midSleep.filter((_, i) => isWeekend(dates[i]!)),
  );

  return {
    meanMidSleep: stats ? formatMinutes(stats.meanMinutes) : null,
    midSleepStdevMin: stats ? round(stats.stdevMinutes) : null,
    n: stats?.n ?? 0,
    socialJetlagMin:
      weekdayMid && weekendMid
        ? round(circularDiffMinutes(weekendMid.meanMinutes, weekdayMid.meanMinutes))
        : null,
  };
}

// ------------------------------------------------------------ 平日 / 休日

const WEEKDAY_WEEKEND_KEYS = ['activity.steps', 'sleep.totalMin', 'coverage.wornHours'];

function buildWeekdayWeekend(
  dates: string[],
  dense: (DailySummary | null)[],
): WeekdayWeekendSplit[] {
  return METRICS.filter((def) => WEEKDAY_WEEKEND_KEYS.includes(def.key)).map((def) => {
    const weekday: (number | null)[] = [];
    const weekend: (number | null)[] = [];
    dense.forEach((d, i) => {
      const v = d ? def.get(d) ?? null : null;
      (isWeekend(dates[i]!) ? weekend : weekday).push(v);
    });

    const wd = mean(weekday);
    const we = mean(weekend);
    return {
      key: def.key,
      label: def.label,
      unit: def.unit,
      weekday: round(wd),
      weekend: round(we),
      diff: wd !== null && we !== null ? round(we - wd) : null,
    };
  });
}

// -------------------------------------------------------------------- 相関

/**
 * 調べる相関の組み合わせ。
 *
 * lagDays は「x の何日後の y を見るか」。睡眠は起床日基準で記録しているため、
 * 「日中の活動が夜の睡眠に効いたか」を見るには y を 1 日ずらす必要がある。
 * ここを 0 にすると、活動する前の晩の睡眠と比べることになり因果が逆転する。
 */
const CORRELATION_PAIRS: { x: string; y: string; lagDays: number; description: string }[] = [
  {
    x: 'sleep.totalMin',
    y: 'hr.restingBpm',
    lagDays: 0,
    description: 'その夜の睡眠時間と、同じ日の安静時心拍',
  },
  {
    x: 'sleep.efficiencyPct',
    y: 'hr.restingBpm',
    lagDays: 0,
    description: 'その夜の睡眠効率と、同じ日の安静時心拍',
  },
  {
    x: 'sleep.totalMin',
    y: 'hrv.rmssdMs',
    lagDays: 0,
    description: 'その夜の睡眠時間と、同じ日の心拍変動',
  },
  {
    x: 'activity.steps',
    y: 'sleep.totalMin',
    lagDays: 1,
    description: '日中の歩数と、その夜の睡眠時間',
  },
  {
    x: 'activity.steps',
    y: 'sleep.deepMin',
    lagDays: 1,
    description: '日中の歩数と、その夜の深い睡眠',
  },
  {
    x: 'activity.exerciseMin',
    y: 'sleep.deepMin',
    lagDays: 1,
    description: '運動時間と、その夜の深い睡眠',
  },
];

function buildCorrelations(
  _dates: string[],
  dense: (DailySummary | null)[],
): CorrelationResult[] {
  const seriesOf = (key: string) => {
    const def = METRICS.find((m) => m.key === key);
    if (!def) throw new Error(`未知の指標: ${key}`);
    return dense.map((d) => (d ? def.get(d) ?? null : null));
  };

  return CORRELATION_PAIRS.map((pair) => {
    const xs = seriesOf(pair.x);
    const ysRaw = seriesOf(pair.y);
    // y を lagDays だけ前に詰めることで、xs[i] と「i 日後の y」を並べる。
    const ys = pair.lagDays === 0 ? ysRaw : ysRaw.slice(pair.lagDays);
    const xsAligned = pair.lagDays === 0 ? xs : xs.slice(0, xs.length - pair.lagDays);

    const result: Correlation | null = pearson(xsAligned, ys);
    return {
      x: pair.x,
      y: pair.y,
      lagDays: pair.lagDays,
      description: pair.description,
      r: result ? round(result.r, 3) : null,
      n: result?.n ?? countPairs(xsAligned, ys),
    };
  });
}

function countPairs(
  xs: readonly (number | null)[],
  ys: readonly (number | null)[],
): number {
  let n = 0;
  for (let i = 0; i < Math.min(xs.length, ys.length); i++) {
    if (typeof xs[i] === 'number' && typeof ys[i] === 'number') n++;
  }
  return n;
}

// ------------------------------------------------------------------ 注意書き

function buildCaveats(
  dates: string[],
  dense: (DailySummary | null)[],
  metrics: MetricSummary[],
): string[] {
  const out: string[] = [];
  const withData = dense.filter((d) => d !== null).length;

  if (withData === 0) {
    out.push('期間内にデータが 1 日もありません。');
    return out;
  }

  const coveragePct = (withData / dates.length) * 100;
  if (coveragePct < 70) {
    out.push(
      `${dates.length} 日中 ${withData} 日分しかデータがありません (${Math.round(coveragePct)}%)。` +
        '傾向の判断には慎重になってください。',
    );
  }

  const worn = compact(dense.map((d) => d?.coverage?.wornHours ?? null));
  const lowWear = worn.filter((h) => h < LOW_WEAR_HOURS).length;
  if (lowWear > 0) {
    out.push(
      `装着時間が ${LOW_WEAR_HOURS} 時間未満の日が ${lowWear} 日あります。` +
        'これらの日の歩数や心拍は実際より低く出ています。',
    );
  }

  const never = metrics.filter((m) => m.n === 0);
  if (never.length > 0) {
    out.push(
      `この期間で一度も取得できなかった指標: ${never.map((m) => m.label).join('、')}。` +
        'デバイスが記録していないため、これらについては何も言えません。',
    );
  }

  if (withData < 14) {
    out.push('データが 2 週間未満のため、移動平均やベースラインとの比較は参考程度に留めてください。');
  }

  return out;
}

// -------------------------------------------------------------------- 補助

/** yyyy-MM-dd を両端含みで列挙する。UTC で計算してタイムゾーンのずれを避ける。 */
export function enumerateDates(from: string, to: string): string[] {
  const start = Date.parse(`${from}T00:00:00Z`);
  const end = Date.parse(`${to}T00:00:00Z`);
  if (Number.isNaN(start) || Number.isNaN(end)) {
    throw new Error(`日付の形式が不正です: ${from} 〜 ${to}`);
  }
  if (end < start) throw new Error(`期間が逆転しています: ${from} 〜 ${to}`);

  const out: string[] = [];
  const day = 24 * 60 * 60 * 1000;
  for (let t = start; t <= end; t += day) {
    out.push(new Date(t).toISOString().slice(0, 10));
  }
  return out;
}

/**
 * ISO 8601 の時刻を「その日の何分か」に変換する。
 *
 * 文字列のオフセット表記をそのまま使う。UTC に正規化してしまうと、
 * 日本時間の 03:00 が 18:00 になり、就寝リズムの分析が崩れる。
 */
function minutesOfDay(iso: string | Date | null | undefined): number | null {
  if (iso === null || iso === undefined) return null;
  const s = iso instanceof Date ? iso.toISOString() : iso;
  const m = /T(\d{2}):(\d{2})/.exec(s);
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

function formatMinutes(minutes: number): string {
  const total = ((Math.round(minutes) % 1440) + 1440) % 1440;
  const h = Math.floor(total / 60);
  const mm = total % 60;
  return `${String(h).padStart(2, '0')}:${String(mm).padStart(2, '0')}`;
}

/** 円周上の差。-720〜+720 分の範囲で、絶対値が最小になる向きを返す。 */
function circularDiffMinutes(a: number, b: number): number {
  let diff = a - b;
  while (diff > 720) diff -= 1440;
  while (diff < -720) diff += 1440;
  return diff;
}

/** yyyy-MM-dd が土日か。UTC で判定する。 */
function isWeekend(date: string): boolean {
  const day = new Date(`${date}T00:00:00Z`).getUTCDay();
  return day === 0 || day === 6;
}
