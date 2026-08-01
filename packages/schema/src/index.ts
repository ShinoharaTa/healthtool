/**
 * healthtool の正準スキーマ。
 *
 * schemas/*.schema.json が唯一の正であり、このパッケージが公開する型はすべて
 * そこから生成される。型を手で足したくなったら、まずスキーマを直すこと。
 *
 *   npm run gen:types   # TypeScript 型と Dart クラスを再生成
 */
export * from './generated';

/** Firestore のコレクションパス。文字列直書きを防ぐため一箇所にまとめる。 */
export const paths = {
  user: (uid: string) => `users/${uid}`,
  daily: (uid: string) => `users/${uid}/daily`,
  dailyDoc: (uid: string, date: string) => `users/${uid}/daily/${date}`,
  intradayDoc: (uid: string, date: string, kind: string) =>
    `users/${uid}/daily/${date}/intraday/${kind}`,
  sleepSessions: (uid: string) => `users/${uid}/sleepSessions`,
  workouts: (uid: string) => `users/${uid}/workouts`,
  insights: (uid: string) => `users/${uid}/insights`,
} as const;

/** daily ドキュメントの現行スキーマバージョン。読み込み側の移行判定に使う。 */
export const DAILY_SCHEMA_VERSION = 1;
