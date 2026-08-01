import type { DailySummary } from '@healthtool/schema';

/**
 * 追跡する指標の定義。
 *
 * `key` はスキーマ上のパスと一致させてある。LLM に「どの指標の話か」を
 * 曖昧さなく引用させるためで、findings がこのキーを名乗れば
 * 入力データのどこを見たのかが機械的に照合できる。
 */
export interface MetricDef {
  key: string;
  label: string;
  unit: string;
  /** 値が大きいほど良いか。悪化・改善の向きを LLM に推測させないために明示する。 */
  direction: 'higher-is-better' | 'lower-is-better' | 'context-dependent';
  get: (d: DailySummary) => number | null | undefined;
}

export const METRICS: readonly MetricDef[] = [
  {
    key: 'activity.steps',
    label: '歩数',
    unit: '歩',
    direction: 'higher-is-better',
    get: (d) => d.activity?.steps,
  },
  {
    key: 'activity.activeKcal',
    label: 'アクティブな消費カロリー',
    unit: 'kcal',
    direction: 'higher-is-better',
    get: (d) => d.activity?.activeKcal,
  },
  {
    key: 'activity.exerciseMin',
    label: '運動時間',
    unit: '分',
    direction: 'higher-is-better',
    get: (d) => d.activity?.exerciseMin,
  },
  {
    key: 'sleep.totalMin',
    label: '睡眠時間',
    unit: '分',
    direction: 'context-dependent',
    get: (d) => d.sleep?.totalMin,
  },
  {
    key: 'sleep.deepMin',
    label: '深い睡眠',
    unit: '分',
    direction: 'higher-is-better',
    get: (d) => d.sleep?.deepMin,
  },
  {
    key: 'sleep.remMin',
    label: 'レム睡眠',
    unit: '分',
    direction: 'higher-is-better',
    get: (d) => d.sleep?.remMin,
  },
  {
    key: 'sleep.awakeMin',
    label: '中途覚醒',
    unit: '分',
    direction: 'lower-is-better',
    get: (d) => d.sleep?.awakeMin,
  },
  {
    key: 'sleep.efficiencyPct',
    label: '睡眠効率',
    unit: '%',
    direction: 'higher-is-better',
    get: (d) => d.sleep?.efficiencyPct,
  },
  {
    key: 'hr.restingBpm',
    label: '安静時心拍',
    unit: 'bpm',
    direction: 'lower-is-better',
    get: (d) => d.hr?.restingBpm,
  },
  {
    key: 'hr.avgBpm',
    label: '平均心拍',
    unit: 'bpm',
    direction: 'context-dependent',
    get: (d) => d.hr?.avgBpm,
  },
  {
    key: 'hrv.rmssdMs',
    label: '心拍変動 (RMSSD)',
    unit: 'ms',
    direction: 'higher-is-better',
    get: (d) => d.hrv?.rmssdMs,
  },
  {
    key: 'spo2.avgPct',
    label: '血中酸素 (平均)',
    unit: '%',
    direction: 'higher-is-better',
    get: (d) => d.spo2?.avgPct,
  },
  {
    key: 'spo2.minPct',
    label: '血中酸素 (最低)',
    unit: '%',
    direction: 'higher-is-better',
    get: (d) => d.spo2?.minPct,
  },
  {
    key: 'body.weightKg',
    label: '体重',
    unit: 'kg',
    direction: 'context-dependent',
    get: (d) => d.body?.weightKg,
  },
  {
    key: 'coverage.wornHours',
    label: '推定装着時間',
    unit: '時間',
    direction: 'context-dependent',
    get: (d) => d.coverage?.wornHours,
  },
];

export const METRIC_BY_KEY: ReadonlyMap<string, MetricDef> = new Map(
  METRICS.map((m) => [m.key, m]),
);
