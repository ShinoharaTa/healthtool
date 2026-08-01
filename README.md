# healthtool

Xiaomi Smart Band の健康データを Health Connect 経由で集約し、統計とグラフで可視化した上で、
LLM (Gemini) に第三者視点で評価させるツール。

## なぜこの構成なのか

- **Xiaomi には公開 API が無い。** Mi Fitness / Zepp Life はサーバー API を出していないため、
  正攻法の取得経路は Android の **Health Connect** のみ。非公式 Huami API は利用規約違反かつ壊れやすいので使わない。
- **Fitbit Web API は 2026年9月に停止する。** 後日 Fitbit を足す場合は Google Health API v4 を使う。
- 結果として「Flutter が端末から吸い上げ → Firestore → Cloud Functions が集計と LLM 評価 → Next.js で閲覧」になる。

```
[Xiaomi Smart Band] --BLE--> [Mi Fitness] --> [Health Connect]
                                                    │
                                         [Flutter Android アプリ]
                                                    │ 端末側で日次集約
                                                    ▼
                                           [Cloud Firestore]
                                              ▲          │
              [Next.js ダッシュボード] ───────┘          ▼
                                                 [Cloud Functions v2]
                                                  集計 / Gemini 評価 / 週次レポート
```

## ディレクトリ

| パス | 中身 |
|---|---|
| `packages/schema/` | **正準スキーマ。** JSON Schema が唯一の正で、TS 型と Dart クラスをここから生成する |
| `app/` | Flutter Android アプリ。Health Connect からの取得と同期 |
| `functions/` | Cloud Functions v2 (TypeScript)。派生統計と Gemini 評価 |
| `web/` | Next.js ダッシュボード |

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

## 開発

```bash
npm run emulators            # Auth + Firestore + Functions のエミュレータ
cd app && flutter run        # Android 実機またはエミュレータ
```

## 注意

このツールは医療機器ではなく、出力は診断ではない。LLM のプロンプトにもその制約を明記してあり、
異常値を検出した場合は受診の検討を促す形でのみ提示する。
