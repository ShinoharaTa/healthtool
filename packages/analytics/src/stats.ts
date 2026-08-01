/**
 * 統計の基礎関数。
 *
 * すべて欠損 (null / undefined / NaN) を「無かったこと」として扱い、
 * 0 に潰さない。健康データでは「歩かなかった 0 歩」と「バンドを着けていない」を
 * 混同した瞬間に、以降の平均も相関も意味を失う。
 */

/** 欠損を除いた有限の数値だけを取り出す。 */
export function compact(values: readonly (number | null | undefined)[]): number[] {
  return values.filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
}

export function mean(values: readonly (number | null | undefined)[]): number | null {
  const xs = compact(values);
  if (xs.length === 0) return null;
  return xs.reduce((a, b) => a + b, 0) / xs.length;
}

/** 標本標準偏差 (n-1)。2 点未満では定義できないので null。 */
export function stdev(values: readonly (number | null | undefined)[]): number | null {
  const xs = compact(values);
  if (xs.length < 2) return null;
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  const variance = xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1);
  return Math.sqrt(variance);
}

export function median(values: readonly (number | null | undefined)[]): number | null {
  const xs = compact(values).sort((a, b) => a - b);
  if (xs.length === 0) return null;
  const mid = xs.length >> 1;
  return xs.length % 2 === 0 ? (xs[mid - 1]! + xs[mid]!) / 2 : xs[mid]!;
}

export function minOf(values: readonly (number | null | undefined)[]): number | null {
  const xs = compact(values);
  return xs.length === 0 ? null : Math.min(...xs);
}

export function maxOf(values: readonly (number | null | undefined)[]): number | null {
  const xs = compact(values);
  return xs.length === 0 ? null : Math.max(...xs);
}

/**
 * 後方移動平均。位置 i の値は i を含む直近 window 個から計算する。
 *
 * 窓の中の有効な点が [minSamples] 未満なら null を返す。
 * 欠損だらけの窓から出した平均を「7日平均」と称して LLM に渡すと、
 * 実際には 1 日分の値でしかないものを傾向として解釈されてしまう。
 */
export function rollingMean(
  values: readonly (number | null | undefined)[],
  window: number,
  minSamples = Math.ceil(window / 2),
): (number | null)[] {
  return values.map((_, i) => {
    const slice = values.slice(Math.max(0, i - window + 1), i + 1);
    const xs = compact(slice);
    if (xs.length < minSamples) return null;
    return xs.reduce((a, b) => a + b, 0) / xs.length;
  });
}

/** 相関の計算結果。n を必ず返し、少数点での相関を過信させない。 */
export interface Correlation {
  /** ピアソンの積率相関係数。 */
  r: number;
  /** 両方の値が揃っていた日数。 */
  n: number;
}

/**
 * ピアソン相関。両方が揃っている組だけを使う (pairwise complete)。
 *
 * n が 8 未満なら null を返す。それ以下の相関係数は偶然と区別がつかず、
 * 数字として提示すると必ず読み違えられる。
 */
export function pearson(
  xs: readonly (number | null | undefined)[],
  ys: readonly (number | null | undefined)[],
  minPairs = 8,
): Correlation | null {
  if (xs.length !== ys.length) {
    throw new Error(`系列の長さが違います: ${xs.length} vs ${ys.length}`);
  }

  const pairs: [number, number][] = [];
  for (let i = 0; i < xs.length; i++) {
    const x = xs[i];
    const y = ys[i];
    if (typeof x === 'number' && Number.isFinite(x) && typeof y === 'number' && Number.isFinite(y)) {
      pairs.push([x, y]);
    }
  }
  if (pairs.length < minPairs) return null;

  const n = pairs.length;
  const mx = pairs.reduce((a, [x]) => a + x, 0) / n;
  const my = pairs.reduce((a, [, y]) => a + y, 0) / n;

  let num = 0;
  let dx2 = 0;
  let dy2 = 0;
  for (const [x, y] of pairs) {
    const dx = x - mx;
    const dy = y - my;
    num += dx * dy;
    dx2 += dx * dx;
    dy2 += dy * dy;
  }
  // どちらかが定数だと相関は定義できない。
  if (dx2 === 0 || dy2 === 0) return null;

  return { r: num / Math.sqrt(dx2 * dy2), n };
}

/**
 * 最小二乗法による傾き。x は 0,1,2,... の日インデックスを使う。
 * 単位は「1日あたりの変化量」。
 */
export function slopePerDay(values: readonly (number | null | undefined)[]): number | null {
  const pairs: [number, number][] = [];
  values.forEach((v, i) => {
    if (typeof v === 'number' && Number.isFinite(v)) pairs.push([i, v]);
  });
  if (pairs.length < 3) return null;

  const n = pairs.length;
  const mx = pairs.reduce((a, [x]) => a + x, 0) / n;
  const my = pairs.reduce((a, [, y]) => a + y, 0) / n;
  let num = 0;
  let den = 0;
  for (const [x, y] of pairs) {
    num += (x - mx) * (y - my);
    den += (x - mx) ** 2;
  }
  if (den === 0) return null;
  return num / den;
}

/**
 * 時刻の円周平均と円周標準偏差。単位は分。
 *
 * 就寝・起床・睡眠中点は 0時をまたぐため、通常の平均や標準偏差では正しく扱えない。
 * 例えば 23:50 と 00:10 の平均は 12:00 ではなく 00:00 でなければならない。
 * 角度に変換して合成ベクトルから求める。
 *
 * @param minutesOfDay 0-1439 の分。欠損は null。
 */
export function circularStats(
  minutesOfDay: readonly (number | null | undefined)[],
): { meanMinutes: number; stdevMinutes: number; n: number } | null {
  const xs = compact(minutesOfDay);
  if (xs.length < 2) return null;

  const toRad = (m: number) => (m / 1440) * 2 * Math.PI;
  let sinSum = 0;
  let cosSum = 0;
  for (const m of xs) {
    sinSum += Math.sin(toRad(m));
    cosSum += Math.cos(toRad(m));
  }

  const n = xs.length;
  const sinBar = sinSum / n;
  const cosBar = cosSum / n;
  // 合成ベクトルの長さ。1 に近いほど時刻が揃っている。
  const r = Math.sqrt(sinBar ** 2 + cosBar ** 2);

  // 完全に対蹠的に散らばると平均方向が定義できない。
  if (r < 1e-9) return null;

  // atan2 は (-π, π] を返す。分に直してから [0, 1440) に畳む。
  // 先に丸めておかないと、0時ちょうどが浮動小数の誤差で
  // -1e-14 分 → 1439.99999... 分 (= 23:59) に化ける。
  let minutes = (Math.atan2(sinBar, cosBar) / (2 * Math.PI)) * 1440;
  minutes = Math.round(minutes * 1e6) / 1e6;
  minutes = ((minutes % 1440) + 1440) % 1440;

  return {
    meanMinutes: minutes,
    // 円周標準偏差。r=1 で 0、散らばるほど大きくなる。
    stdevMinutes: (Math.sqrt(-2 * Math.log(r)) / (2 * Math.PI)) * 1440,
    n,
  };
}

/** 小数の桁を揃える。JSON に載せる直前にだけ使う。 */
export function round(value: number | null, digits = 2): number | null {
  if (value === null || !Number.isFinite(value)) return null;
  const f = 10 ** digits;
  return Math.round(value * f) / f;
}
