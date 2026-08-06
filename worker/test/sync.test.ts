import { Miniflare } from 'miniflare';
import { beforeAll, afterAll, describe, expect, it } from 'vitest';

const TOKEN = 'test-token-abc';

let mf: Miniflare;

interface JsonBody {
  error?: string;
  message?: string;
  serverTime?: number;
  applied?: Array<{ id: string; updatedAt: number }>;
  blobs?: any[];
}

async function push(body: unknown, opts: { token?: string; protocol?: string } = {}) {
  const token = opts.token ?? TOKEN;
  const protocol = opts.protocol ?? '1';
  return mf.dispatchFetch('http://localhost/sync/push', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${token}`,
      'x-sync-protocol': protocol,
    },
    body: JSON.stringify(body),
  });
}

async function pull(since = 0, opts: { token?: string; protocol?: string } = {}) {
  const token = opts.token ?? TOKEN;
  const protocol = opts.protocol ?? '1';
  return mf.dispatchFetch('http://localhost/sync/pull', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${token}`,
      'x-sync-protocol': protocol,
    },
    body: JSON.stringify({ deviceId: 'dev-a', since }),
  });
}

function envDoc(id: string, updatedAt = 1000, deleted = false, device = 'dev-a') {
  return {
    t: 'doc',
    id,
    data: { notebookId: 'nb1', title: '第一章', contentDelta: {}, words: 0 },
    deleted,
    updatedAt,
    device,
    schemaVersion: 1,
  };
}

beforeAll(async () => {
  mf = new Miniflare({
    modules: true,
    scriptPath: './dist/index.mjs', // pretest 用 esbuild 预编译（miniflare 不解析 TS）
    bindings: { SYNC_TOKEN: TOKEN },
    r2Buckets: ['ZIZAI_BUCKET'],
  });
});

afterAll(async () => {
  await mf.dispose();
});

describe('鉴权与协议', () => {
  it('无 token → 401', async () => {
    const res = await push({ blobs: [] }, { token: '' });
    expect(res.status).toBe(401);
    const body = (await res.json()) as JsonBody;
    expect(body.error).toBe('unauthorized');
  });

  it('错误 token → 401', async () => {
    const res = await push({ blobs: [] }, { token: 'wrong' });
    expect(res.status).toBe(401);
  });

  it('X-Sync-Protocol 不匹配 → 409', async () => {
    const res = await push({ schemaVersion: 1, blobs: [] }, { protocol: '2' });
    expect(res.status).toBe(409);
    expect(((await res.json()) as JsonBody).error).toBe('protocol_mismatch');
  });

  it('schemaVersion 不匹配 → 409', async () => {
    const res = await push({ schemaVersion: 2, blobs: [] });
    expect(res.status).toBe(409);
    expect(((await res.json()) as JsonBody).error).toBe('schema_mismatch');
  });

  it('未知路径 → 404，错误响应不含敏感信息', async () => {
    const res = await mf.dispatchFetch('http://localhost/nope', { method: 'POST' });
    expect(res.status).toBe(404);
    const text = await res.text();
    expect(text).not.toContain(TOKEN);
    expect(text).not.toContain('Bearer');
  });
});

describe('push', () => {
  it('合法推送 → applied + serverTime，时间戳由服务器签发', async () => {
    const res = await push({
      deviceId: 'dev-a',
      schemaVersion: 1,
      blobs: [envDoc('d1', 1)],
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as JsonBody;
    expect(Array.isArray(body.applied)).toBe(true);
    expect(body.applied!).toHaveLength(1);
    expect(body.applied![0].id).toBe('d1');
    // 服务器时间戳覆盖客户端时间（客户端传 1，服务器返回当前时间）
    expect(body.applied![0].updatedAt).toBeGreaterThan(1_700_000_000_000);
    expect(typeof body.serverTime).toBe('number');
  });

  it('LWW：同一文档二次推送覆盖，updatedAt 递增', async () => {
    await push({ deviceId: 'dev-a', schemaVersion: 1, blobs: [envDoc('lww', 1)] });
    const first = await pull(0);
    const b1 = ((await first.json()) as JsonBody).blobs!.find((x) => x.id === 'lww');
    await push({ deviceId: 'dev-b', schemaVersion: 1, blobs: [envDoc('lww', 999999, false, 'dev-b')] });
    const second = await pull(0);
    const b2 = ((await second.json()) as JsonBody).blobs!.find((x) => x.id === 'lww');
    // 覆盖写生效：第二版来自 dev-b；客户端时间被服务器时间覆盖
    expect(b2.device).toBe('dev-b');
    expect(b2.updatedAt).toBeGreaterThanOrEqual(b1.updatedAt);
    expect(b2.updatedAt).not.toBe(999_999); // 客户端时间被服务器时间覆盖
  });

  it('tombstone：deleted 文档可推送并被拉取', async () => {
    await push({ deviceId: 'dev-a', schemaVersion: 1, blobs: [envDoc('gone', 1, true)] });
    const res = await pull(0);
    const blobs = ((await res.json()) as JsonBody).blobs!;
    const gone = blobs.find((x: { id: string }) => x.id === 'gone');
    expect(gone).toBeDefined();
    expect(gone.deleted).toBe(true);
  });

  it('非法 envelope 被跳过，不写 R2', async () => {
    await push({
      deviceId: 'dev-a',
      schemaVersion: 1,
      blobs: [envDoc('good', 1), { t: 'bad-type', id: 'x' }],
    });
    const res = await pull(0);
    const blobs = ((await res.json()) as JsonBody).blobs!;
    // 非法 envelope 被跳过：'x' 不入库
    expect(blobs.find((x) => x.id === 'good')).toBeDefined();
    expect(blobs.find((x) => x.id === 'x')).toBeUndefined();
  });
});

describe('pull', () => {
  it('since=0 返回全部；since=最新返回空', async () => {
    await push({ deviceId: 'dev-a', schemaVersion: 1, blobs: [envDoc('p1', 1)] });
    const all = await pull(0);
    expect(((await all.json()) as JsonBody).blobs!.filter((x) => x.id === 'p1')).toHaveLength(1);

    const latest = await pull(9_999_999_999_999);
    expect(((await latest.json()) as JsonBody).blobs).toHaveLength(0);
  });

  it('since 过滤：只返回更新的', async () => {
    const first = await pull(0);
    const serverTime = ((await first.json()) as JsonBody).serverTime!;
    await push({ deviceId: 'dev-a', schemaVersion: 1, blobs: [envDoc('p2', 1)] });
    const res = await pull(serverTime);
    const blobs = ((await res.json()) as JsonBody).blobs!;
    expect(blobs).toHaveLength(1);
    expect(blobs[0].id).toBe('p2');
  });

  it('R2 对象按布局落键（docs/{id}.json）', async () => {
    await push({ deviceId: 'dev-a', schemaVersion: 1, blobs: [envDoc('layout-1', 1)] });
    const store = await mf.getR2Bucket('ZIZAI_BUCKET');
    const obj = await store.get('zizai/db/docs/layout-1.json');
    expect(obj).not.toBeNull();
    const parsed = JSON.parse(await obj!.text());
    expect(parsed.id).toBe('layout-1');
    expect(parsed.t).toBe('doc');
  });
});
