/// <reference types="@cloudflare/workers-types" />

/** 云同步 blob 统一 envelope（docs/app/sync.md §3）。 */
export interface Envelope {
  t: 'doc' | 'notebook' | 'settings' | 'stats';
  id: string;
  data: unknown;
  deleted: boolean;
  updatedAt: number;
  device: string;
  schemaVersion: number;
}

export interface Env {
  ZIZAI_BUCKET: R2Bucket;
  SYNC_TOKEN: string;
}

const PROTOCOL_VERSION = 1;
const SCHEMA_VERSION = 1;
const DB_PREFIX = 'zizai/db/';

const BLOB_TYPES = new Set(['doc', 'notebook', 'settings', 'stats']);

/** R2 对象键（docs/app/sync.md §3 布局）。 */
export function keyFor(t: string, id: string): string | null {
  switch (t) {
    case 'doc':
      return `${DB_PREFIX}docs/${id}.json`;
    case 'notebook':
      return `${DB_PREFIX}notebooks/${id}.json`;
    case 'settings':
      return `${DB_PREFIX}settings.json`;
    case 'stats':
      return `${DB_PREFIX}stats.json`;
    default:
      return null;
  }
}

export function isEnvelope(value: unknown): value is Envelope {
  if (typeof value !== 'object' || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.t === 'string' &&
    BLOB_TYPES.has(v.t) &&
    typeof v.id === 'string' &&
    typeof v.data === 'object' &&
    v.data !== null &&
    typeof v.deleted === 'boolean' &&
    typeof v.device === 'string' &&
    typeof v.schemaVersion === 'number'
  );
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

/** 常量时间比较，避免 token 时序侧信道。 */
function tokenEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get('Authorization') ?? '';
  if (!header.startsWith('Bearer ')) return false;
  const token = header.slice('Bearer '.length);
  return token.length > 0 && tokenEquals(token, env.SYNC_TOKEN);
}

async function readJson(request: Request): Promise<unknown | null> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

async function handlePush(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env))) {
    return json({ error: 'unauthorized' }, 401);
  }
  if (request.headers.get('X-Sync-Protocol') !== String(PROTOCOL_VERSION)) {
    return json({ error: 'protocol_mismatch', message: '客户端协议过旧，请升级 App' }, 409);
  }
  const body = await readJson(request);
  if (body === null || typeof body !== 'object') {
    return json({ error: 'bad_request' }, 400);
  }
  const b = body as Record<string, unknown>;
  if (b.schemaVersion !== SCHEMA_VERSION) {
    return json({ error: 'schema_mismatch', message: '数据版本过旧，请升级 App' }, 409);
  }
  // 时间戳一律由服务器签发，不接受客户端时钟。
  const serverTime = Date.now();
  const applied: Array<{ id: string; updatedAt: number }> = [];
  const blobs = Array.isArray(b.blobs) ? (b.blobs as unknown[]) : [];
  for (const raw of blobs) {
    if (!isEnvelope(raw)) continue;
    const envelope: Envelope = { ...raw, updatedAt: serverTime };
    const key = keyFor(envelope.t, envelope.id);
    if (key === null) continue;
    await env.ZIZAI_BUCKET.put(key, JSON.stringify(envelope), {
      httpMetadata: { contentType: 'application/json' },
    });
    applied.push({ id: envelope.id, updatedAt: serverTime });
  }
  return json({ serverTime, applied });
}

async function handlePull(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env))) {
    return json({ error: 'unauthorized' }, 401);
  }
  if (request.headers.get('X-Sync-Protocol') !== String(PROTOCOL_VERSION)) {
    return json({ error: 'protocol_mismatch', message: '客户端协议过旧，请升级 App' }, 409);
  }
  const body = await readJson(request);
  if (body === null || typeof body !== 'object') {
    return json({ error: 'bad_request' }, 400);
  }
  const since =
    typeof (body as Record<string, unknown>).since === 'number'
      ? ((body as Record<string, unknown>).since as number)
      : 0;

  const blobs: Envelope[] = [];
  let cursor: string | undefined;
  do {
    const listed = await env.ZIZAI_BUCKET.list({ prefix: DB_PREFIX, cursor });
    for (const obj of listed.objects) {
      const got = await env.ZIZAI_BUCKET.get(obj.key);
      if (got === null) continue;
      let envelope: unknown;
      try {
        envelope = JSON.parse(await got.text());
      } catch {
        continue; // 损坏对象跳过，不影响同步
      }
      if (
        isEnvelope(envelope) &&
        typeof envelope.updatedAt === 'number' &&
        envelope.updatedAt > since
      ) {
        blobs.push(envelope);
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor !== undefined);

  return json({ serverTime: Date.now(), blobs });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === 'POST' && url.pathname === '/sync/push') {
      return handlePush(request, env);
    }
    if (request.method === 'POST' && url.pathname === '/sync/pull') {
      return handlePull(request, env);
    }
    return json({ error: 'not_found' }, 404);
  },
};
