# Firebase のセットアップ

アプリは Firebase が未設定でも「ローカルモード」で起動し、Health Connect の
Capability Probe だけは実行できる。サインインと Firestore への保存を有効にするには以下を行う。

## 1. Firebase プロジェクトを作る

[Firebase コンソール](https://console.firebase.google.com/) で新規プロジェクトを作成する。
Google アナリティクスは不要。

有効化するもの:

- **Authentication** → Sign-in method → **Google** を有効化
- **Firestore Database** → 本番モードで作成、ロケーションは `asia-northeast1`
- **Vertex AI** (M2 で使う) → Google Cloud コンソール側で Vertex AI API を有効化

## 2. Android アプリの SHA-1 を登録する

Google サインインは署名証明書のフィンガープリントが一致しないと ID トークンを返さない。
**これを飛ばすと「サインインに失敗しました」だけが出て原因が分からなくなる。**

```bash
cd app/android
./gradlew signingReport
```

出力の `Variant: debug` の SHA1 を、Firebase コンソールの
プロジェクト設定 → マイアプリ → Android アプリ → 「フィンガープリントを追加」に登録する。

リリースビルドを配る際は、リリース用キーストアの SHA-1 も追加する。
Play Console の内部テストを使う場合は、**Play アプリ署名の SHA-1** も必要になる
(Play Console → テストとリリース → アプリの整合性 → アプリ署名鍵の証明書)。

## 3. flutterfire configure を実行する

```bash
dart pub global activate flutterfire_cli
cd app
flutterfire configure --project=<プロジェクトID> --platforms=android
```

これで以下が生成・配置される:

- `app/lib/firebase_options.dart`
- `app/android/app/google-services.json`
- `app/android/` の Gradle に google-services プラグインが追加される

どちらも `.gitignore` 済み。リポジトリにはコミットしない。

## 4. serverClientId を渡す

`google-services.json` の `oauth_client` から `client_type: 3` (Web クライアント) の
`client_id` を控え、実行時に渡す。

```bash
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=<...>.apps.googleusercontent.com
```

未指定でも Android では `google-services.json` から解決されることがあるが、
明示したほうが失敗の切り分けが楽になる。

## 5. ルールとインデックスを反映する

```bash
firebase login
firebase use --add        # プロジェクトを選び、エイリアスを default にする
firebase deploy --only firestore:rules,firestore:indexes
```

## 6. 動作確認

1. `flutter run` でアプリを起動し、Google サインインする
2. 「今すぐ同期」を実行
3. Firebase コンソール → Firestore で `users/{uid}/daily/{今日の日付}` が出来ているか確認
4. 中身の歩数・睡眠時間を Mi Fitness アプリの表示値と照合する

値がずれる場合は、まずタイムゾーンの日境界処理を疑う。
`daily` ドキュメントの `tz` が `Asia/Tokyo` になっているかを確認すること。

## エミュレータで開発する

Firebase プロジェクトを作らずに Firestore の挙動だけ試したい場合:

```bash
npm run emulators
```

Auth (9099) / Firestore (8080) / Functions (5001) / UI (4000) が上がる。
アプリからエミュレータに向けるには `main.dart` で `useFirestoreEmulator` を呼ぶ必要があり、
現時点では未実装。
