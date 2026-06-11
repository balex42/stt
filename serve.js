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

function cacheControl(pathname) {
  if (pathname.startsWith('/vendor/') || pathname.startsWith('/models/')) {
    return 'public, max-age=31536000, immutable';
  }
  return 'no-cache';
}

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
    const headers = {
      'Content-Type': MIME[extname(filePath)] ?? 'application/octet-stream',
      'Accept-Ranges': 'bytes',
      'Cache-Control': cacheControl(pathname),
      ...SECURITY,
    };

    const rangeHeader = req.headers.range;
    if (rangeHeader) {
      const match = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
      if (match) {
        const start = parseInt(match[1], 10);
        const end   = Math.min(match[2] ? parseInt(match[2], 10) : size - 1, size - 1);
        if (start > end || start >= size) {
          res.writeHead(416, { ...SECURITY, 'Content-Range': `bytes */${size}` });
          res.end();
          return;
        }
        res.writeHead(206, {
          ...headers,
          'Content-Length': end - start + 1,
          'Content-Range':  `bytes ${start}-${end}/${size}`,
        });
        if (req.method === 'HEAD') { res.end(); return; }
        createReadStream(filePath, { start, end }).pipe(res);
        return;
      }
      // multi-range or unrecognised format — fall through to 200
    }

    res.writeHead(200, { ...headers, 'Content-Length': size });
    if (req.method === 'HEAD') { res.end(); return; }
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404, SECURITY);
    res.end('Not found');
  }
}).listen(8000, '0.0.0.0', () => console.log('Ready → http://localhost:8000'));
