/**
 * サービスアカウントによる Google API アクセストークンの取得。
 *
 * Workers には Node の crypto も firebase-admin も無いので、
 * WebCrypto で RS256 の JWT を自分で組み立てて署名し、
 * OAuth 2.0 の JWT bearer フローでアクセストークンに交換する。
 */

const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';

/** google-services.json ではなく、サービスアカウントの JSON 鍵。 */
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export function parseServiceAccount(raw: string): ServiceAccount {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new Error('FIREBASE_SERVICE_ACCOUNT が JSON として読めません');
  }
  const sa = json as Partial<ServiceAccount>;
  if (!sa.project_id || !sa.client_email || !sa.private_key) {
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT に project_id / client_email / private_key が揃っていません',
    );
  }
  return sa as ServiceAccount;
}

const encoder = new TextEncoder();

function base64url(input: ArrayBuffer | string): string {
  const bytes =
    typeof input === 'string' ? encoder.encode(input) : new Uint8Array(input);
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** PEM の PKCS#8 秘密鍵を WebCrypto の CryptoKey に変換する。 */
async function importPrivateKey(pem: string): Promise<CryptoKey> {
  // 環境変数経由だと改行が \n のままなことが多いので戻す。
  const normalized = pem.includes('\\n') ? pem.replace(/\\n/g, '\n') : pem;
  const body = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');

  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  return crypto.subtle.importKey(
    'pkcs8',
    bytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

interface CachedToken {
  token: string;
  /** 失効時刻（ミリ秒）。 */
  expiresAt: number;
}

/**
 * アクセストークンを取得してメモリにキャッシュする。
 *
 * Durable Object のインスタンスが生きている間は使い回す。
 * トークンは 1 時間有効なので、ツール呼び出しのたびに JWT を署名し直すのは無駄。
 */
export class GoogleTokenProvider {
  constructor(
    private readonly sa: ServiceAccount,
    private readonly scopes: readonly string[],
  ) {}

  private cache: CachedToken | null = null;

  get projectId(): string {
    return this.sa.project_id;
  }

  async getToken(): Promise<string> {
    // 失効の 60 秒前には取り直す。境界ぎりぎりで 401 を食うのを避ける。
    if (this.cache && this.cache.expiresAt - Date.now() > 60_000) {
      return this.cache.token;
    }

    const now = Math.floor(Date.now() / 1000);
    const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const claims = base64url(
      JSON.stringify({
        iss: this.sa.client_email,
        scope: this.scopes.join(' '),
        aud: TOKEN_ENDPOINT,
        iat: now,
        exp: now + 3600,
      }),
    );

    const key = await importPrivateKey(this.sa.private_key);
    const signature = await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      key,
      encoder.encode(`${header}.${claims}`),
    );
    const jwt = `${header}.${claims}.${base64url(signature)}`;

    const res = await fetch(TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: jwt,
      }),
    });

    if (!res.ok) {
      throw new Error(
        `Google のアクセストークン取得に失敗しました (${res.status}): ${await res.text()}`,
      );
    }

    const body = (await res.json()) as { access_token: string; expires_in: number };
    this.cache = {
      token: body.access_token,
      expiresAt: Date.now() + body.expires_in * 1000,
    };
    return body.access_token;
  }
}

/** Firestore と Identity Toolkit を叩くのに必要なスコープ。 */
export const FIRESTORE_SCOPES = [
  'https://www.googleapis.com/auth/datastore',
  'https://www.googleapis.com/auth/firebase',
] as const;
