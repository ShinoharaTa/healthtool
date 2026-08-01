import OAuthProvider from '@cloudflare/workers-oauth-provider';

import { googleHandler } from './google-handler';
import { HealthMcp } from './mcp-agent';

export { HealthMcp };

/**
 * healthtool のリモート MCP サーバー。
 *
 * この Worker は OAuth の両側を兼ねる。
 *   - Claude に対しては OAuth サーバー。動的クライアント登録と PKCE を
 *     workers-oauth-provider が処理する。
 *   - Google に対しては OAuth クライアント。本人確認だけを委譲し、
 *     許可リストに載っているアカウントかを検証する（google-handler.ts）。
 *
 * 健康データそのものへのアクセスは Google 側の権限ではなく、この Worker が持つ
 * サービスアカウントで行う。利用者の Google トークンは本人確認以外に使わず、保存もしない。
 */
export default new OAuthProvider({
  // MCP 本体。ここに来る時点で認可は済んでおり、uid は props に入っている。
  apiRoute: '/mcp',
  apiHandler: HealthMcp.serve('/mcp', { binding: 'HEALTH_MCP' }) as never,

  // 認可画面とコールバック。
  defaultHandler: googleHandler as never,

  authorizeEndpoint: '/authorize',
  tokenEndpoint: '/token',
  // Claude は接続時に自分自身をクライアントとして登録する。
  clientRegistrationEndpoint: '/register',
});
