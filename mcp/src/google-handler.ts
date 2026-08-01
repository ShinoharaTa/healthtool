import type { AuthRequest } from '@cloudflare/workers-oauth-provider';

import { FIRESTORE_SCOPES, GoogleTokenProvider, parseServiceAccount } from './google-auth';
import { IdentityLookup, isAllowed, parseAllowlist } from './identity';
import type { Env } from './types';

/**
 * Claude からの認可要求を Google に委譲するハンドラ。
 *
 * この Worker は二重の役割を持つ。
 *   - Claude に対しては OAuth サーバー（workers-oauth-provider が担当）
 *   - Google に対しては OAuth クライアント（このファイルが担当）
 *
 * 流れ:
 *   Claude → /authorize → Google の同意画面 → /callback → Claude に戻る
 */

const GOOGLE_AUTHORIZE = 'https://accounts.google.com/o/oauth2/v2/auth';
const GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token';

/** Google 往復の間だけ認可要求を預けておく KV のキー接頭辞。 */
const STATE_PREFIX = 'pending-auth:';
const STATE_TTL_SECONDS = 600;

export const googleHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    switch (url.pathname) {
      case '/authorize':
        return handleAuthorize(request, env, url);
      case '/callback':
        return handleCallback(request, env, url);
      case '/':
        return new Response(
          'healthtool MCP サーバー。Claude のカスタムコネクタとして /mcp を登録してください。',
          { headers: { 'content-type': 'text/plain; charset=utf-8' } },
        );
      default:
        return new Response('Not found', { status: 404 });
    }
  },
};

async function handleAuthorize(request: Request, env: Env, url: URL): Promise<Response> {
  const authRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
  if (!authRequest.clientId) {
    return errorPage('不正な認可要求です', 'client_id がありません。', 400);
  }

  // Google の state に載せられるのは短い文字列なので、
  // 認可要求そのものは KV に預けてランダムなキーだけを往復させる。
  // 要求を state に直接詰めると改ざんの検証が必要になり、実装を誤りやすい。
  const stateKey = crypto.randomUUID();
  await env.OAUTH_KV.put(STATE_PREFIX + stateKey, JSON.stringify(authRequest), {
    expirationTtl: STATE_TTL_SECONDS,
  });

  const params = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${url.origin}/callback`,
    response_type: 'code',
    scope: 'openid email profile',
    state: stateKey,
    // リフレッシュトークンは不要。健康データへのアクセスは
    // この Worker のサービスアカウントで行い、Google 側の権限は本人確認にしか使わない。
    access_type: 'online',
    prompt: 'select_account',
  });

  return Response.redirect(`${GOOGLE_AUTHORIZE}?${params}`, 302);
}

async function handleCallback(request: Request, env: Env, url: URL): Promise<Response> {
  const googleError = url.searchParams.get('error');
  if (googleError) {
    return errorPage('Google の認証が中断されました', googleError, 400);
  }

  const code = url.searchParams.get('code');
  const stateKey = url.searchParams.get('state');
  if (!code || !stateKey) {
    return errorPage('不正なコールバックです', 'code または state がありません。', 400);
  }

  const stored = await env.OAUTH_KV.get(STATE_PREFIX + stateKey);
  if (!stored) {
    return errorPage(
      '認可要求の有効期限が切れました',
      'もう一度 Claude 側から接続をやり直してください。',
      400,
    );
  }
  await env.OAUTH_KV.delete(STATE_PREFIX + stateKey);
  const authRequest = JSON.parse(stored) as AuthRequest;

  // 認可コードを ID トークンに交換する。
  const tokenRes = await fetch(GOOGLE_TOKEN, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: `${url.origin}/callback`,
      grant_type: 'authorization_code',
    }),
  });

  if (!tokenRes.ok) {
    return errorPage('Google のトークン交換に失敗しました', await tokenRes.text(), 502);
  }

  const { id_token: idToken } = (await tokenRes.json()) as { id_token?: string };
  if (!idToken) {
    return errorPage('Google から ID トークンが返りませんでした', '', 502);
  }

  const claims = decodeIdToken(idToken);
  if (!claims?.email) {
    return errorPage('Google の応答にメールアドレスがありません', '', 502);
  }
  if (!claims.email_verified) {
    return errorPage(
      'メールアドレスが未確認です',
      'Google 側でメールアドレスの確認を済ませてください。',
      403,
    );
  }

  const allowlist = parseAllowlist(env.ALLOWED_EMAILS);
  if (!isAllowed(allowlist, claims.email)) {
    return errorPage(
      'このアカウントは許可されていません',
      `${claims.email} は接続を許可されたアカウントの一覧にありません。`,
      403,
    );
  }

  // Google アカウント → Firebase uid。
  const tokens = new GoogleTokenProvider(
    parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT),
    FIRESTORE_SCOPES,
  );
  const uid = await new IdentityLookup(tokens).uidForEmail(claims.email);
  if (!uid) {
    return errorPage(
      'healthtool のアカウントが見つかりません',
      `${claims.email} は healthtool アプリでまだサインインしていないようです。` +
        'Android アプリで一度サインインしてから接続し直してください。',
      404,
    );
  }

  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: authRequest,
    userId: uid,
    scope: authRequest.scope,
    metadata: { label: claims.email },
    props: { uid, email: claims.email, name: claims.name ?? null },
  });

  return Response.redirect(redirectTo, 302);
}

interface IdTokenClaims {
  sub: string;
  email?: string;
  email_verified?: boolean;
  name?: string;
}

/**
 * ID トークンのペイロードを読む。
 *
 * 署名は検証していない。このトークンは Google のトークンエンドポイントから
 * TLS 越しに直接受け取ったものなので、OpenID Connect Core 3.1.3.7 が
 * 署名検証を省略してよいと定めている場合に当たる。
 * ブラウザ経由で受け取ったトークンには、この理屈は使えない。
 */
function decodeIdToken(idToken: string): IdTokenClaims | null {
  const parts = idToken.split('.');
  if (parts.length !== 3) return null;
  try {
    const payload = parts[1]!.replace(/-/g, '+').replace(/_/g, '/');
    const json = atob(payload.padEnd(payload.length + ((4 - (payload.length % 4)) % 4), '='));
    // atob はバイト列を返すので、UTF-8 の名前が化けないよう復号する。
    const bytes = Uint8Array.from(json, (c) => c.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes)) as IdTokenClaims;
  } catch {
    return null;
  }
}

function errorPage(title: string, detail: string, status: number): Response {
  const escape = (s: string) =>
    s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
  return new Response(
    `<!doctype html><meta charset="utf-8">
<title>${escape(title)}</title>
<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.7}
h1{font-size:1.25rem}p{color:#444}</style>
<h1>${escape(title)}</h1>
<p>${escape(detail)}</p>`,
    { status, headers: { 'content-type': 'text/html; charset=utf-8' } },
  );
}
