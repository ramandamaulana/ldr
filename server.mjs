import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));

async function loadEnvFile() {
  try {
    const contents = await readFile(join(root, '.env.local'), 'utf8');
    for (const line of contents.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const i = trimmed.indexOf('=');
      if (i < 1) continue;
      const name = trimmed.slice(0, i).trim();
      let value = trimmed.slice(i + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
      if (!process.env[name]) process.env[name] = value;
    }
  } catch { /* Environment variables may be supplied by the hosting service. */ }
}

await loadEnvFile();

const server = createServer(async (req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (pathname === '/.well-known/ldr-config') {
    // Only browser-safe values are exposed. Never place a Supabase secret/service_role key here.
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ url: process.env.SUPABASE_URL || '', key: process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || '' }));
    return;
  }
  if (pathname === '/setup.sql') {
    try {
      const sql = await readFile(join(root, 'setup.sql'));
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Disposition': 'attachment; filename="setup.sql"' });
      res.end(sql);
    } catch { res.writeHead(404); res.end('setup.sql not found'); }
    return;
  }
  if (pathname === '/' || pathname === '/index.html') {
    try {
      const html = await readFile(join(root, 'index.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
      res.end(html);
    } catch { res.writeHead(500); res.end('index.html not found'); }
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

const port = Number(process.env.PORT || 3000);
server.listen(port, '0.0.0.0', () => console.log(`Jauh Dekat ready at http://localhost:${port}`));
