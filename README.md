# healthtool

Xiaomi Smart Band の健康データを Health Connect 経由で集約し、統計とグラフで可視化した上で、
LLM (Gemini) に第三者視点で評価させるツール。

## なぜこの構成なのか

- **Xiaomi には公開 API が無い。** Mi Fitness / Zepp Life はサーバー API を出していないため、
  正攻法の取得経路は Android の **Health Connect** のみ。非公式 Huami API は利用規約違反かつ壊れやすいので使わない。
- **Fitbit Web API は 2026年9月に停止する。** 後日 Fitbit を足す場合は Google Health API v4 を使う。
- 結果として「Flutter が端末から吸い上げ → Firestore → リモート MCP サーバー → Claude が評価」になる。

評価は LLM を組み込んだ定型レポートではなく、**Claude から引く pull 型**にしてある。
固定プロンプトの週次レポートでは追加質問ができず、健康データの探索はまさにそこが要るため。

```
[Xiaomi Smart Band] --BLE--> [Mi Fitness] --> [Health Connect]
                                                    │
                                         [Flutter Android アプリ]
                                                    │ 端末側で日次集約
                                                    ▼
                                           [Cloud Firestore]
                                                    │
                                    [Cloudflare Workers: MCP サーバー]
                                       OAuth (Google 委譲 + 許可リスト)
                                       派生統計を計算して返す
                                                    │
                                    [Claude — Web / モバイル / Code]
```

## ディレクトリ

| パス | 中身 |
|---|---|
| `packages/schema/` | **正準スキーマ。** JSON Schema が唯一の正で、TS 型と Dart クラスをここから生成する |
| `packages/analytics/` | 派生統計。移動平均・就寝リズム・遅れ相関・欠損率。純粋関数のみ |
| `app/` | Flutter Android アプリ。Health Connect からの取得と同期 |
| `mcp/` | リモート MCP サーバー (Cloudflare Workers)。Claude からの参照口 |

## スキーマと型生成

`packages/schema/schemas/*.schema.json` を編集したら、必ず再生成する。
生成物 (`packages/schema/src/generated/`, `app/lib/models/generated/`) は git 管理外なので、
チェックアウト直後にも一度実行する必要がある。

```bash
npm install
npm run gen:types
```

型を手で書き足したくなったら、まずスキーマを直すこと。

## セットアップ

必要なもの: Node 20+, Flutter 3.44+, Android Studio (JDK 同梱), Firebase CLI。

```bash
npm install                  # ルートで実行。workspaces を解決する
npm run gen:types            # TS 型と Dart モデルを生成
cd app && flutter pub get
```

Firebase プロジェクトの紐付けはまだ行っていない。`docs/setup-firebase.md` を参照。
MCP サーバーのデプロイ手順は `docs/setup-mcp.md`。

## 開発

```bash
npm test                     # 全ワークスペースのテスト
npm run typecheck
npm run emulators            # Auth + Firestore のエミュレータ
cd app && flutter test       # 日次集約のテスト
cd app && flutter run        # Android 実機またはエミュレータ
cd mcp && npx wrangler dev   # MCP サーバーをローカル起動
```

## CI

`.github/workflows/ci.yml` が push と PR で走る。

| ジョブ | 内容 |
|---|---|
| `node` | スキーマから型を生成 → ビルド → テスト → 型検査 |
| `flutter` | Dart モデルを生成 → `dart format` の確認 → `flutter analyze --fatal-infos` → テスト |
| `android` | デバッグ APK をビルドし、**マージ後のマニフェストに Health Connect の設定が残っているかを検証** |

生成コードは追跡していないので、どのジョブも先に `npm run gen:types` を通す。

`android` ジョブのマニフェスト検証は、権限宣言や `activity-alias` を消しても
静的解析では気付けないため入れてある。これらが欠けると Health Connect から
データが一切読めなくなり、実機に入れるまで分からない。

MCP サーバーのデプロイ (`deploy-mcp.yml`) は手動実行のみ。
`CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` をリポジトリの secret に登録して使う。

## 注意

このツールは医療機器ではなく、出力は診断ではない。LLM のプロンプトにもその制約を明記してあり、
異常値を検出した場合は受診の検討を促す形でのみ提示する。
