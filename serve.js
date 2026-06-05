import { createServer } from 'http';
import { createReadStream } from 'fs';
import { stat } from 'fs/promises';
import { extname, join, resolve } from 'path';

const STATIC_ROOT = resolve('static');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.mjs':  'application/javascript',
  '.css':  'text/css',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
};

const SECURITY = {
  'Cross-Origin-Opener-Policy':   'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'X-Content-Type-Options':       'nosniff',
  'X-Frame-Options':              'SAMEORIGIN',
  'Referrer-Policy':              'no-referrer',
};

createServer(async (req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { ...SECURITY, Allow: 'GET, HEAD' });
    res.end();
    return;
  }

  // URL constructor normalises '..' sequences (can't traverse above /)
  let pathname;
  try { pathname = new URL(req.url, 'http://x').pathname; }
  catch { res.writeHead(400, SECURITY); res.end(); return; }

  const filePath = resolve(join(STATIC_ROOT, pathname === '/' ? 'index.html' : pathname));

  // Belt-and-suspenders: reject anything that resolved outside static/
  if (filePath !== STATIC_ROOT && !filePath.startsWith(STATIC_ROOT + '/')) {
    res.writeHead(403, SECURITY);
    res.end('Forbidden');
    return;
  }

  try {
    const { size } = await stat(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[extname(filePath)] ?? 'application/octet-stream',
      'Content-Length': size,
      ...SECURITY,
    });
    if (req.method === 'HEAD') { res.end(); return; }
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404, SECURITY);
    res.end('Not found');
  }
}).listen(8000, '0.0.0.0', () => console.log('Ready → http://localhost:8000'));
