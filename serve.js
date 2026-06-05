import { createServer } from 'http';
import { createReadStream } from 'fs';
import { stat } from 'fs/promises';
import { extname, join } from 'path';

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
};

createServer(async (req, res) => {
  const filePath = join('static', req.url === '/' ? 'index.html' : req.url);
  try {
    const { size } = await stat(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[extname(filePath)] ?? 'application/octet-stream',
      'Content-Length': size,
      ...SECURITY,
    });
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404, SECURITY);
    res.end('Not found');
  }
}).listen(8000, '0.0.0.0', () => console.log('Ready → http://localhost:8000'));
