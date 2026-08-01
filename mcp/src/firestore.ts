import { GoogleTokenProvider } from './google-auth';

/**
 * Firestore REST API の薄いクライアント。
 *
 * Workers では firebase-admin が動かないので REST を直接叩く。
 * REST は値を型タグ付きで表現する ({"integerValue": "42"} など) ため、
 * 素の JSON との相互変換をここに閉じ込める。
 */

const BASE = 'https://firestore.googleapis.com/v1';

type FirestoreValue = Record<string, unknown>;

interface FirestoreDocument {
  name: string;
  fields?: Record<string, FirestoreValue>;
  createTime?: string;
  updateTime?: string;
}

/** Firestore の型付き値を素の JS の値に戻す。 */
function decodeValue(value: FirestoreValue): unknown {
  if ('nullValue' in value) return null;
  if ('booleanValue' in value) return value.booleanValue;
  // integerValue は精度落ちを避けるため文字列で返ってくる。
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return Number(value.doubleValue);
  if ('stringValue' in value) return value.stringValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('bytesValue' in value) return value.bytesValue;
  if ('referenceValue' in value) return value.referenceValue;
  if ('geoPointValue' in value) return value.geoPointValue;
  if ('arrayValue' in value) {
    const arr = (value.arrayValue as { values?: FirestoreValue[] }).values ?? [];
    return arr.map(decodeValue);
  }
  if ('mapValue' in value) {
    return decodeFields((value.mapValue as { fields?: Record<string, FirestoreValue> }).fields);
  }
  return null;
}

function decodeFields(fields?: Record<string, FirestoreValue>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(fields ?? {})) out[k] = decodeValue(v);
  return out;
}

/** 素の JS の値を Firestore の型付き値にする。 */
function encodeValue(value: unknown): FirestoreValue {
  if (value === null || value === undefined) return { nullValue: null };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') {
    return Number.isInteger(value)
      ? { integerValue: String(value) }
      : { doubleValue: value };
  }
  if (typeof value === 'string') return { stringValue: value };
  if (Array.isArray(value)) {
    return { arrayValue: { values: value.map(encodeValue) } };
  }
  if (typeof value === 'object') {
    return { mapValue: { fields: encodeFields(value as Record<string, unknown>) } };
  }
  return { nullValue: null };
}

function encodeFields(obj: Record<string, unknown>): Record<string, FirestoreValue> {
  const out: Record<string, FirestoreValue> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined) continue;
    out[k] = encodeValue(v);
  }
  return out;
}

/** ドキュメント ID をフルパスから切り出す。 */
function docId(name: string): string {
  return name.slice(name.lastIndexOf('/') + 1);
}

export class FirestoreClient {
  constructor(private readonly tokens: GoogleTokenProvider) {}

  private get root(): string {
    return `${BASE}/projects/${this.tokens.projectId}/databases/(default)/documents`;
  }

  private async request(url: string, init?: RequestInit): Promise<unknown> {
    const token = await this.tokens.getToken();
    const res = await fetch(url, {
      ...init,
      headers: {
        ...(init?.headers ?? {}),
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
    });
    if (!res.ok) {
      throw new Error(`Firestore の呼び出しに失敗しました (${res.status}): ${await res.text()}`);
    }
    return res.json();
  }

  /** 単一ドキュメントを読む。存在しなければ null。 */
  async getDocument(path: string): Promise<{ id: string; data: Record<string, unknown> } | null> {
    const token = await this.tokens.getToken();
    const res = await fetch(`${this.root}/${path}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (res.status === 404) return null;
    if (!res.ok) {
      throw new Error(`Firestore の取得に失敗しました (${res.status}): ${await res.text()}`);
    }
    const doc = (await res.json()) as FirestoreDocument;
    return { id: docId(doc.name), data: decodeFields(doc.fields) };
  }

  /**
   * コレクションを範囲指定で読む。
   *
   * ドキュメント ID が日付のコレクションを想定し、__name__ ではなく
   * ドキュメント内の [orderField] で絞る。ID による範囲指定は
   * REST だとフルパスを組む必要があり、間違えやすいため使わない。
   */
  async queryRange(options: {
    parent: string;
    collectionId: string;
    field: string;
    from: string;
    to: string;
    limit?: number;
  }): Promise<{ id: string; data: Record<string, unknown> }[]> {
    const body = {
      structuredQuery: {
        from: [{ collectionId: options.collectionId }],
        where: {
          compositeFilter: {
            op: 'AND',
            filters: [
              {
                fieldFilter: {
                  field: { fieldPath: options.field },
                  op: 'GREATER_THAN_OR_EQUAL',
                  value: { stringValue: options.from },
                },
              },
              {
                fieldFilter: {
                  field: { fieldPath: options.field },
                  op: 'LESS_THAN_OR_EQUAL',
                  value: { stringValue: options.to },
                },
              },
            ],
          },
        },
        orderBy: [{ field: { fieldPath: options.field }, direction: 'ASCENDING' }],
        ...(options.limit ? { limit: options.limit } : {}),
      },
    };

    const result = (await this.request(`${this.root}/${options.parent}:runQuery`, {
      method: 'POST',
      body: JSON.stringify(body),
    })) as { document?: FirestoreDocument }[];

    return result
      .filter((r): r is { document: FirestoreDocument } => Boolean(r.document))
      .map((r) => ({ id: docId(r.document.name), data: decodeFields(r.document.fields) }));
  }

  /** コレクションを新しい順に読む。 */
  async queryLatest(options: {
    parent: string;
    collectionId: string;
    orderField: string;
    limit: number;
  }): Promise<{ id: string; data: Record<string, unknown> }[]> {
    const body = {
      structuredQuery: {
        from: [{ collectionId: options.collectionId }],
        orderBy: [{ field: { fieldPath: options.orderField }, direction: 'DESCENDING' }],
        limit: options.limit,
      },
    };

    const result = (await this.request(`${this.root}/${options.parent}:runQuery`, {
      method: 'POST',
      body: JSON.stringify(body),
    })) as { document?: FirestoreDocument }[];

    return result
      .filter((r): r is { document: FirestoreDocument } => Boolean(r.document))
      .map((r) => ({ id: docId(r.document.name), data: decodeFields(r.document.fields) }));
  }

  /** ドキュメントを作成または全置換する。 */
  async setDocument(path: string, data: Record<string, unknown>): Promise<void> {
    // updateMask を付けないと PATCH がマージになるため、
    // 全フィールドを列挙して置換の意味にする。
    const mask = Object.keys(data)
      .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
      .join('&');
    await this.request(`${this.root}/${path}?${mask}`, {
      method: 'PATCH',
      body: JSON.stringify({ fields: encodeFields(data) }),
    });
  }
}

/**
 * 1 ユーザーに固定したリポジトリ。
 *
 * uid はコンストラクタでしか渡せない。ツールの引数から uid を受け取れる形にすると、
 * 実装のどこか 1 箇所で検証を忘れた瞬間に他人の健康データが読めてしまう。
 */
export class UserRepository {
  constructor(
    private readonly client: FirestoreClient,
    private readonly uid: string,
  ) {}

  private get base(): string {
    return `users/${this.uid}`;
  }

  async dailies(from: string, to: string): Promise<Record<string, unknown>[]> {
    const docs = await this.client.queryRange({
      parent: this.base,
      collectionId: 'daily',
      field: 'date',
      from,
      to,
    });
    return docs.map((d) => d.data);
  }

  async sleepSessions(from: string, to: string): Promise<Record<string, unknown>[]> {
    const docs = await this.client.queryRange({
      parent: this.base,
      collectionId: 'sleepSessions',
      field: 'date',
      from,
      to,
    });
    return docs.map((d) => d.data);
  }

  async workouts(from: string, to: string): Promise<Record<string, unknown>[]> {
    const docs = await this.client.queryRange({
      parent: this.base,
      collectionId: 'workouts',
      field: 'date',
      from,
      to,
    });
    return docs.map((d) => d.data);
  }

  async intradayHr(date: string): Promise<Record<string, unknown> | null> {
    const doc = await this.client.getDocument(`${this.base}/daily/${date}/intraday/hr`);
    return doc?.data ?? null;
  }

  async profile(): Promise<Record<string, unknown> | null> {
    const doc = await this.client.getDocument(this.base);
    return doc?.data ?? null;
  }

  async recentInsights(limit: number): Promise<Record<string, unknown>[]> {
    const docs = await this.client.queryLatest({
      parent: this.base,
      collectionId: 'insights',
      orderField: 'createdAt',
      limit,
    });
    return docs.map((d) => d.data);
  }

  async saveInsight(id: string, data: Record<string, unknown>): Promise<void> {
    await this.client.setDocument(`${this.base}/insights/${id}`, data);
  }
}
