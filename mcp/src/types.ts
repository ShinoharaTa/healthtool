import type { OAuthHelpers } from '@cloudflare/workers-oauth-provider';

/**
 * 認可が済んだあと、MCP のツール側に渡る情報。
 *
 * ここに載せた値は OAuth のグラントに紐づけて保存され、
 * 以降のリクエストで検証済みのものとして扱える。
 * uid はこの経路でしか入ってこない。ツールの引数からは絶対に受け取らない。
 */
export interface Props extends Record<string, unknown> {
  /** Firebase Auth の uid。Firestore のパスはこれだけで決まる。 */
  uid: string;
  email: string;
  name: string | null;
}

export interface Env {
  /** OAuth のグラントとトークンの保管先。 */
  OAUTH_KV: KVNamespace;
  /** McpAgent の Durable Object バインディング。 */
  HEALTH_MCP: DurableObjectNamespace;
  /** workers-oauth-provider が注入するヘルパー。 */
  OAUTH_PROVIDER: OAuthHelpers;

  /** 上流 Google OAuth のクライアント（Web アプリケーション種別）。 */
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  /** Firebase のサービスアカウント鍵（JSON 文字列）。 */
  FIREBASE_SERVICE_ACCOUNT: string;
  /** 接続を許可する Google アカウント。カンマ区切り。 */
  ALLOWED_EMAILS: string;
}
