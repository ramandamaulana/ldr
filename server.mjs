import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const dist = resolve(root, 'dist');

async function loadEnvFile() {
  for (const file of ['.env.local', '.env']) {
    try {
      const contents = await readFile(join(root, file), 'utf8');
      for (const line of contents.split(/\r?\n/)) {
        const entry = line.trim();
        if (!entry || entry.startsWith('#')) continue;
        const splitAt = entry.indexOf('=');
        if (splitAt < 1) continue;
        const name = entry.slice(0, splitAt).trim();
        let value = entry.slice(splitAt + 1).trim();
        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
        if (!process.env[name]) process.env[name] = value;
      }
    } catch { /* Hosted deployments inject environment variables directly. */ }
  }
}

await loadEnvFile();

const contentTypes = { '.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.mjs':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.json':'application/json; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.ico':'image/x-icon','.woff2':'font/woff2' };
const server = createServer(async (request, response) => {
  response.setHeader('X-Content-Type-Options','nosniff');
  response.setHeader('X-Frame-Options','DENY');
  response.setHeader('Referrer-Policy','strict-origin-when-cross-origin');
  response.setHeader('Permissions-Policy','camera=(), microphone=(), geolocation=()');
  const url = new URL(request.url || '/', 'http://localhost');
  if (url.pathname === '/healthz') {
    response.writeHead(200, { 'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store' });
    response.end('ok'); return;
  }
  if (url.pathname === '/.well-known/ldr-config') {
    response.writeHead(200, { 'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store' });
    response.end(JSON.stringify({ url:process.env.SUPABASE_URL || '', key:process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || '' })); return;
  }
  if (url.pathname === '/setup.sql') {
    try {
      const sql = await readFile(join(root,'setup.sql'));
      response.writeHead(200, { 'Content-Type':'text/plain; charset=utf-8','Content-Disposition':'attachment; filename="setup.sql"','Cache-Control':'no-store' });
      response.end(sql);
    } catch { response.writeHead(404); response.end('setup.sql belum tersedia'); }
    return;
  }
  let relative;
  try { relative = decodeURIComponent(url.pathname).replace(/^\/+/, ''); } catch { response.writeHead(400); response.end('Bad request'); return; }
  let target = resolve(dist, relative || 'index.html');
  if (target !== dist && !target.startsWith(dist + sep)) { response.writeHead(404); response.end('Not found'); return; }
  try {
    const metadata = await stat(target);
    if (metadata.isDirectory()) target = join(target,'index.html');
    const body = await readFile(target);
    const ext = extname(target);
    response.writeHead(200, { 'Content-Type':contentTypes[ext] || 'application/octet-stream', 'Cache-Control':ext==='.html'?'no-cache':'public, max-age=31536000, immutable' });
    response.end(body);
  } catch {
    if (extname(url.pathname)) { response.writeHead(404); response.end('Not found'); return; }
    try {
      const html = await readFile(join(dist,'index.html'));
      response.writeHead(200, { 'Content-Type':contentTypes['.html'], 'Cache-Control':'no-cache' });
      response.end(html);
    } catch { response.writeHead(503); response.end('Aplikasi belum dibuild. Jalankan npm run build.'); }
  }
});

const port = Number(process.env.PORT || 3000);
server.listen(port,'0.0.0.0',()=>console.log(`Jauh Dekat ready on port ${port}`));
