import { buildTrendReport } from '@healthtool/analytics';
import type { DailySummary } from '@healthtool/schema';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { McpAgent } from 'agents/mcp';
import { z } from 'zod';

import { MAX_RANGE_DAYS, resolveRange, todayIn } from './dates';
import { FirestoreClient, UserRepository } from './firestore';
import { FIRESTORE_SCOPES, GoogleTokenProvider, parseServiceAccount } from './google-auth';
import type { Env, Props } from './types';

const SERVER_INSTRUCTIONS = `
このサーバーは利用者本人のウェアラブル（Xiaomi スマートバンド）の健康データを提供する。

守ること:
- 数値を述べるときは必ずツールが返した実際の値を引用する。記憶や推定で数字を作らない。
- get_trends が返す coverage と caveats を先に読む。装着時間が短い日や欠損の多い期間では、
  傾向を断定せず確信度を下げる。取得できていない指標について推測で語らない。
- 睡眠は「起床日」で記録されている。2026-08-01 の睡眠は 7月31日の夜に寝て 8月1日の朝に起きた分。
- 相関には lagDays が付いている。0 は同日、1 は「その日の活動と、その夜（翌日付）の睡眠」。
  向きを取り違えると因果が逆になるので description を読むこと。
- 相関係数は n が小さいと偶然と区別できない。n も併せて提示する。
- 診断や処方はしない。医学的に気になる数値があれば、断定せず受診の検討を促す形で伝える。
`.trim();

/** Firestore から読んだ生データを、そのまま LLM に渡してよい形に整える。 */
function asDaily(rows: Record<string, unknown>[]): DailySummary[] {
  return rows as unknown as DailySummary[];
}

function json(value: unknown) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }] };
}

function failure(message: string) {
  return {
    content: [{ type: 'text' as const, text: message }],
    isError: true,
  };
}

export class HealthMcp extends McpAgent<Env, never, Props> {
  server = new McpServer(
    { name: 'healthtool', version: '0.1.0' },
    { instructions: SERVER_INSTRUCTIONS },
  );

  private repoCache: UserRepository | null = null;
  private timeZoneCache: string | null = null;

  /**
   * OAuth を通った利用者の情報。
   *
   * 型の上では props が未設定でもコンパイルが通ってしまうため、
   * ここで一度だけ確かめる。uid の無いまま Firestore のパスを組むと
   * `users/undefined` を読みに行き、静かに空の結果を返してしまう。
   */
  private get auth(): Props {
    const props = this.props as Props | undefined;
    if (!props?.uid) {
      throw new Error('認可情報がありません。OAuth を経由しない呼び出しです。');
    }
    return props;
  }

  /**
   * 認可済みの uid に固定したリポジトリ。
   *
   * uid は props からしか取らない。ツールの引数に uid を生やすと、
   * 検証を 1 箇所忘れただけで他人の健康データが読めてしまう。
   */
  private get repo(): UserRepository {
    if (!this.repoCache) {
      const tokens = new GoogleTokenProvider(
        parseServiceAccount(this.env.FIREBASE_SERVICE_ACCOUNT),
        FIRESTORE_SCOPES,
      );
      this.repoCache = new UserRepository(new FirestoreClient(tokens), this.auth.uid);
    }
    return this.repoCache;
  }

  /** 利用者のタイムゾーン。「今日」の解釈に使う。 */
  private async timeZone(): Promise<string> {
    if (this.timeZoneCache) return this.timeZoneCache;
    const profile = await this.repo.profile();
    const tz = (profile?.profile as { timezone?: string } | undefined)?.timezone;
    this.timeZoneCache = tz ?? 'Asia/Tokyo';
    return this.timeZoneCache;
  }

  async init() {
    const rangeArgs = {
      from: z.string().optional().describe('開始日 (yyyy-MM-dd)。省略すると to から遡る。'),
      to: z.string().optional().describe('終了日 (yyyy-MM-dd)。省略すると今日。'),
    };

    this.server.registerTool(
      'get_health_overview',
      {
        description:
          'まずこれを呼ぶ。利用者のプロフィール、データが存在する期間、直近の記録日を返す。' +
          'どの期間について聞かれているかを決める前の下調べに使う。',
        inputSchema: {},
      },
      async () => {
        const tz = await this.timeZone();
        const today = todayIn(tz);
        // 直近1年を走査して、実際にデータがある範囲を掴む。
        const recent = asDaily(await this.repo.dailies(shift(today, -364), today));

        if (recent.length === 0) {
          return json({
            timeZone: tz,
            today,
            hasData: false,
            note:
              'この1年間に日次データがありません。Android アプリで同期が済んでいない可能性があります。',
          });
        }

        const latest = recent[recent.length - 1]!;
        return json({
          user: { email: this.auth.email, name: this.auth.name },
          timeZone: tz,
          today,
          hasData: true,
          dataRange: { first: recent[0]!.date, last: latest.date, daysWithData: recent.length },
          latestDay: latest,
          availableMetrics: describeAvailability(recent),
          hint: `傾向を見るには get_trends を、日々の生の値を見るには get_daily_summaries を呼ぶ。一度に読めるのは ${MAX_RANGE_DAYS} 日まで。`,
        });
      },
    );

    this.server.registerTool(
      'get_trends',
      {
        description:
          '指定期間の派生統計を返す。移動平均、直近7日と前7日の差、傾き、就寝リズムの安定度、' +
          '平日と休日の差、遅れを考慮した相関、欠損状況をまとめて計算済みで返す。' +
          '傾向について何か述べる前に必ずこれを呼ぶこと。生データから自分で平均を暗算しない。',
        inputSchema: rangeArgs,
      },
      async (args) => {
        const tz = await this.timeZone();
        const range = resolveRange(args, tz, 28);
        const dailies = asDaily(await this.repo.dailies(range.from, range.to));
        return json(buildTrendReport(dailies, range));
      },
    );

    this.server.registerTool(
      'get_daily_summaries',
      {
        description:
          '指定期間の日次サマリーを日付順に返す。特定の日の値を確認したいときや、' +
          '発言の根拠として実際の数値を引用したいときに使う。' +
          '取得できなかった指標は null で、0 とは区別されている。',
        inputSchema: rangeArgs,
      },
      async (args) => {
        const tz = await this.timeZone();
        const range = resolveRange(args, tz, 14);
        const dailies = await this.repo.dailies(range.from, range.to);
        return json({ range, count: dailies.length, days: dailies });
      },
    );

    this.server.registerTool(
      'get_sleep_detail',
      {
        description:
          '睡眠セッションの詳細を返す。就寝と起床の時刻、睡眠ステージの時系列が含まれる。' +
          '日付は起床日。中途覚醒の位置や、特定の夜の中身を見たいときに使う。',
        inputSchema: rangeArgs,
      },
      async (args) => {
        const tz = await this.timeZone();
        const range = resolveRange(args, tz, 7);
        const sessions = await this.repo.sleepSessions(range.from, range.to);
        return json({ range, count: sessions.length, sessions });
      },
    );

    this.server.registerTool(
      'get_workouts',
      {
        description: '指定期間の運動セッションを返す。種別、時間、消費カロリー、距離。',
        inputSchema: rangeArgs,
      },
      async (args) => {
        const tz = await this.timeZone();
        const range = resolveRange(args, tz, 28);
        const workouts = await this.repo.workouts(range.from, range.to);
        return json({ range, count: workouts.length, workouts });
      },
    );

    this.server.registerTool(
      'get_intraday_hr',
      {
        description:
          '指定した1日の心拍を5分刻みで返す。1日あたり最大288点と大きいので、' +
          'その日の中の変動を具体的に調べる必要があるときだけ呼ぶ。' +
          '日をまたぐ傾向は get_trends で足りる。',
        inputSchema: {
          date: z.string().describe('対象日 (yyyy-MM-dd)'),
        },
      },
      async ({ date }) => {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
          return failure(`date は yyyy-MM-dd 形式で指定してください（受け取った値: ${date}）`);
        }
        const data = await this.repo.intradayHr(date);
        if (!data) return json({ date, samples: [], note: 'この日の心拍データはありません。' });
        return json({ date, ...data });
      },
    );

    this.server.registerTool(
      'list_insights',
      {
        description:
          '過去に保存した評価を新しい順に返す。前回どう評価したかを踏まえて話すときに使う。',
        inputSchema: {
          limit: z.number().int().min(1).max(20).default(5).describe('取得件数'),
        },
      },
      async ({ limit }) => {
        const insights = await this.repo.recentInsights(limit);
        return json({ count: insights.length, insights });
      },
    );

    this.server.registerTool(
      'save_insight',
      {
        description:
          '今回の評価を記録として残す。あとから「前回何と言われたか」を振り返れるようにするためのもの。' +
          '利用者に評価を伝えたあと、保存してよいか確認してから呼ぶこと。' +
          'evidence には必ず、ツールが実際に返した数値だけを入れる。',
        inputSchema: {
          period: z.enum(['daily', 'weekly', 'monthly']).describe('評価の粒度'),
          startDate: z.string().describe('評価対象期間の開始日 (yyyy-MM-dd)'),
          endDate: z.string().describe('評価対象期間の終了日 (yyyy-MM-dd)'),
          headline: z.string().describe('この期間を一文で言い切った見出し'),
          findings: z
            .array(
              z.object({
                metric: z
                  .string()
                  .describe('対象指標のキー。get_trends の metrics[].key と一致させる'),
                observation: z.string().describe('読み取れた事実'),
                evidence: z
                  .array(
                    z.object({
                      label: z.string(),
                      value: z.number(),
                      unit: z.string().optional(),
                      date: z.string().optional(),
                    }),
                  )
                  .min(1)
                  .describe('根拠となる実際の数値'),
                confidence: z.enum(['high', 'medium', 'low']),
              }),
            )
            .min(1)
            .max(6),
          recommendations: z
            .array(
              z.object({
                action: z.string(),
                rationale: z.string(),
                effort: z.enum(['low', 'medium', 'high']),
              }),
            )
            .min(1)
            .max(4),
          watchouts: z
            .array(z.object({ signal: z.string(), suggestion: z.string() }))
            .max(3)
            .default([])
            .describe('医学的に気になる点。無ければ空配列。無理に埋めない'),
          dataGaps: z.array(z.string()).default([]).describe('評価の妨げになった欠損'),
        },
      },
      async (args) => {
        const now = new Date().toISOString();
        const id = `${args.period}-${args.endDate}-${now.slice(11, 19).replace(/:/g, '')}`;

        await this.repo.saveInsight(id, {
          schemaVersion: 1,
          id,
          period: args.period,
          startDate: args.startDate,
          endDate: args.endDate,
          // どのモデルが書いたかを残す。後から結果を比較するのに要る。
          model: 'claude-via-mcp',
          inputHash: '',
          createdAt: now,
          body: {
            headline: args.headline,
            findings: args.findings,
            recommendations: args.recommendations,
            watchouts: args.watchouts,
            dataGaps: args.dataGaps,
          },
        });

        return json({ saved: true, id, createdAt: now });
      },
    );
  }
}

function shift(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000)
    .toISOString()
    .slice(0, 10);
}

/**
 * どの指標が実際に取れているかを数える。
 *
 * Mi Fitness が Health Connect に何を書くかは端末次第で、SpO2 や心拍変動は
 * 取れないことが多い。取れていない指標について語らせないために、
 * 最初の概要で明示する。
 */
function describeAvailability(dailies: DailySummary[]): Record<string, number> {
  const count = (pick: (d: DailySummary) => unknown) =>
    dailies.filter((d) => {
      const v = pick(d);
      return v !== null && v !== undefined;
    }).length;

  return {
    steps: count((d) => d.activity?.steps),
    sleep: count((d) => d.sleep?.totalMin),
    sleepStages: count((d) => d.sleep?.deepMin),
    restingHeartRate: count((d) => d.hr?.restingBpm),
    heartRate: count((d) => d.hr?.avgBpm),
    hrv: count((d) => d.hrv?.rmssdMs),
    spo2: count((d) => d.spo2?.avgPct),
    weight: count((d) => d.body?.weightKg),
    workouts: count((d) => d.workouts?.count),
  };
}
