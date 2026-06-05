import { createServer } from 'http';
import { readFile } from 'fs/promises';
import { extname, join } from 'path';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.wasm': 'application/wasm',
};

const SECURITY = {
  'Cross-Origin-Opener-Policy':   'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
};

createServer(async (req, res) => {
  const filePath = join('static', req.url === '/' ? 'index.html' : req.url);
  try {
    const data = await readFile(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[extname(filePath)] ?? 'application/octet-stream',
      ...SECURITY,
    });
    res.end(data);
  } catch {
    res.writeHead(404, SECURITY);
    res.end('Not found');
  }
}).listen(8000, '0.0.0.0', () => console.log('Ready → http://localhost:8000'));
