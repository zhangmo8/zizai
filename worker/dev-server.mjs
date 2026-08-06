// 本地起真实 Worker（miniflare + workerd）供集成测试连接。
// 用法：node dev-server.mjs（PORT / SYNC_TOKEN 环境变量可配）
import { Miniflare } from 'miniflare';
import http from 'node:http';

const port = Number(process.env.PORT ?? 8787);
const token = process.env.SYNC_TOKEN ?? 'dev-token';

const mf = new Miniflare({
  modules: true,
  scriptPath: './dist/index.mjs', // 需先 esbuild 打包（见 package.json pretest）
  bindings: { SYNC_TOKEN: token },
  r2Buckets: ['ZIZAI_BUCKET'],
});

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const body = await readBody(req);
    const url = new URL(req.url, 'http://localhost');
    const resp = await mf.dispatchFetch(url.toString(), {
      method: req.method,
      headers: req.headers,
      body: body.length ? body : undefined,
    });
    const headers = {};
    resp.headers.forEach((v, k) => (headers[k] = v));
    res.writeHead(resp.status, headers);
    res.end(Buffer.from(await resp.arrayBuffer()));
  } catch (e) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: String(e) }));
  }
});

server.listen(port, () => {
  console.log(`READY ${port}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    await mf.dispose();
    server.close();
    process.exit(0);
  });
}
