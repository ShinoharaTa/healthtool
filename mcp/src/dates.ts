/** 期間指定の既定値と検証。 */

/** 一度に読める最大日数。これ以上はトークンも Firestore の読み取りも無駄に膨らむ。 */
export const MAX_RANGE_DAYS = 400;

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** 指定タイムゾーンでの「今日」を yyyy-MM-dd で返す。 */
export function todayIn(timeZone: string): string {
  // en-CA のロケールは yyyy-MM-dd 形式を返す。手で組み立てるより取り違えが少ない。
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

export function shiftDays(date: string, days: number): string {
  const t = Date.parse(`${date}T00:00:00Z`);
  if (Number.isNaN(t)) throw new Error(`日付の形式が不正です: ${date}`);
  return new Date(t + days * 86_400_000).toISOString().slice(0, 10);
}

export function daysBetween(from: string, to: string): number {
  return Math.round(
    (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000,
  ) + 1;
}

/**
 * 期間を確定させる。
 *
 * 未指定なら「今日を終端とする直近 defaultDays 日」。
 * 日付だけ渡されたときに、どの時間帯の今日なのかを曖昧にしないよう
 * タイムゾーンを必ず受け取る。
 */
export function resolveRange(
  args: { from?: string; to?: string },
  timeZone: string,
  defaultDays: number,
): { from: string; to: string } {
  for (const [name, value] of Object.entries(args)) {
    if (value !== undefined && !DATE_RE.test(value)) {
      throw new Error(`${name} は yyyy-MM-dd 形式で指定してください（受け取った値: ${value}）`);
    }
  }

  const to = args.to ?? todayIn(timeZone);
  const from = args.from ?? shiftDays(to, -(defaultDays - 1));

  if (from > to) {
    throw new Error(`期間が逆転しています: ${from} 〜 ${to}`);
  }
  const span = daysBetween(from, to);
  if (span > MAX_RANGE_DAYS) {
    throw new Error(
      `一度に指定できるのは ${MAX_RANGE_DAYS} 日までです（指定された期間: ${span} 日）。` +
        '期間を分けて呼び出してください。',
    );
  }

  return { from, to };
}
