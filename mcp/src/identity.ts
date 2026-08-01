import { GoogleTokenProvider } from './google-auth';

/**
 * Google アカウントから Firebase の uid を引く。
 *
 * Flutter アプリは Firebase Auth の uid で Firestore に書いている。
 * MCP サーバーは Google に対して直接認証するので、そのままでは
 * どのユーザーのデータを読めばよいか分からない。
 * Identity Toolkit に問い合わせて対応付ける。
 *
 * Firestore の users コレクションにメールアドレスを持たせて検索する手もあるが、
 * それだと「アプリが email を書いていること」に依存し、書き漏れると
 * 静かに別人扱いになる。Identity Toolkit は Firebase Auth 自身の記録なので権威的。
 */
export class IdentityLookup {
  constructor(private readonly tokens: GoogleTokenProvider) {}

  /** メールアドレスに対応する Firebase uid。未登録なら null。 */
  async uidForEmail(email: string): Promise<string | null> {
    const token = await this.tokens.getToken();
    const res = await fetch(
      `https://identitytoolkit.googleapis.com/v1/projects/${this.tokens.projectId}/accounts:lookup`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ email: [email] }),
      },
    );

    if (!res.ok) {
      throw new Error(
        `Firebase のユーザー照会に失敗しました (${res.status}): ${await res.text()}`,
      );
    }

    const body = (await res.json()) as { users?: { localId: string }[] };
    return body.users?.[0]?.localId ?? null;
  }
}

/**
 * 許可リスト。カンマ区切りのメールアドレス。
 *
 * 身内配布の想定なので、認可の粒度はこれで足りる。
 * Firebase に登録済みでも、ここに無いアカウントは接続できない。
 */
export function parseAllowlist(raw: string | undefined): Set<string> {
  return new Set(
    (raw ?? '')
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
  );
}

export function isAllowed(allowlist: Set<string>, email: string): boolean {
  // 空の許可リストを「全員許可」と解釈しない。設定漏れで全世界に開くほうが事故として重い。
  if (allowlist.size === 0) return false;
  return allowlist.has(email.trim().toLowerCase());
}
