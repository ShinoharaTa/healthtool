# MCP サーバーのセットアップ

`mcp/` は Cloudflare Workers 上で動くリモート MCP サーバー。
Claude（Web・モバイル・デスクトップ・Claude Code）から、Firestore に溜めた健康データを
会話で参照するための入口になる。

前提として、Flutter アプリで一度サインインして同期を済ませてあること。
MCP サーバーは Firebase Auth に登録済みのアカウントしか受け付けない。

## 仕組み

この Worker は OAuth の両側を兼ねる。

- **Claude に対しては OAuth サーバー** — 動的クライアント登録と PKCE を
  `@cloudflare/workers-oauth-provider` が処理する
- **Google に対しては OAuth クライアント** — 本人確認だけを委譲し、
  許可リストに載っているアカウントかを検証する

健康データそのものへのアクセスは、利用者の Google 権限ではなく Worker の
サービスアカウントで行う。利用者の Google トークンは本人確認以外に使わず、保存もしない。

Google アカウントから Firebase の uid を引くのに Identity Toolkit を使う。
Firestore のパスはこの uid だけで決まり、ツールの引数からは uid を一切受け取らない。

## 1. Google OAuth クライアントを作る

Google Cloud コンソール（Firebase と同じプロジェクト）→ API とサービス → 認証情報 →
「OAuth クライアント ID を作成」→ 種類は **ウェブアプリケーション**。

承認済みのリダイレクト URI に、デプロイ後の URL を登録する:

```
https://healthtool-mcp.<サブドメイン>.workers.dev/callback
```

クライアント ID とシークレットを控える。

## 2. サービスアカウント鍵を用意する

Firebase コンソール → プロジェクトの設定 → サービスアカウント → 「新しい秘密鍵の生成」。
ダウンロードした JSON をそのまま secret に入れる（ファイルはリポジトリに置かない）。

## 3. KV 名前空間を作る

```bash
cd mcp
npx wrangler kv namespace create OAUTH_KV
```

出力された id を `wrangler.jsonc` の `PLACEHOLDER_KV_NAMESPACE_ID` と差し替える。

## 4. secret を設定する

```bash
cd mcp
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put FIREBASE_SERVICE_ACCOUNT   # JSON をそのまま貼る
npx wrangler secret put ALLOWED_EMAILS             # カンマ区切り
```

`ALLOWED_EMAILS` に載っていないアカウントは接続できない。
**空にすると全員拒否**になる（全員許可ではない）。設定漏れで健康データが
外に開くほうが事故として重いため、意図的にそうしてある。

## 5. デプロイ

```bash
cd mcp
npx wrangler deploy
```

## 6. Claude から接続する

claude.ai → 設定 → コネクタ → カスタムコネクタを追加。URL は:

```
https://healthtool-mcp.<サブドメイン>.workers.dev/mcp
```

接続すると Google の同意画面が出る。許可リストにあるアカウントで承認すれば、
以降は Claude のモバイルアプリからも同じコネクタが使える。

Claude Code から使う場合:

```bash
claude mcp add --transport http healthtool https://healthtool-mcp.<サブドメイン>.workers.dev/mcp
```

## ツール

| ツール | 用途 |
|---|---|
| `get_health_overview` | 最初に呼ぶ。データのある期間、直近の記録、取得できている指標 |
| `get_trends` | 移動平均・前週比・傾き・就寝リズム・相関・欠損状況。**傾向を語る前に必ずこれ** |
| `get_daily_summaries` | 日次の生の値。発言の根拠として数値を引用するとき |
| `get_sleep_detail` | 睡眠ステージの時系列 |
| `get_workouts` | 運動セッション |
| `get_intraday_hr` | 1日の心拍を5分刻み（最大288点なので明示的に必要なときだけ） |
| `list_insights` / `save_insight` | 評価の記録と読み返し |

`get_trends` が集計を確定させてから渡すのが要点。90日分の生データを直接読ませて
傾向の抽出をモデルの暗算に任せると、数字の取り違えが起きる。

## 開発

```bash
cd mcp
npm run typecheck
npm test                    # 期間の解決と許可リストの単体テスト
npx wrangler dev            # ローカル起動（secret は .dev.vars に置く）
```

`.dev.vars` は `.gitignore` 済み。

## 注意

会話に載せた健康データは Claude の履歴に残る。
評価そのものを残したい場合は `save_insight` で Firestore に書ける。
