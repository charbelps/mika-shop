// Local preview of the website, for trying changes on this PC before they go online.
// Serves the docs\ folder at http://localhost:8080/mika-shop/ (same paths as GitHub Pages).
// Pages opened from here use the TEST database (see docs\js\config.js), even after launch.
// Only reachable from this PC. No install needed, just Node.js.
//
// Start (PowerShell, in the mika-shop folder):   node tools\preview-server.js
// Stop: Ctrl+C in that window.
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..', 'docs');
const PORT = 8080;
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.csv': 'text/csv; charset=utf-8', '.txt': 'text/plain; charset=utf-8',
};
const server = http.createServer((req, res) => {
  let p;
  try { p = decodeURIComponent(new URL(req.url, 'http://x').pathname); } catch { res.writeHead(400); return res.end(); }
  if (!p.startsWith('/mika-shop/')) { res.writeHead(302, { Location: '/mika-shop/' }); return res.end(); }
  p = p.slice('/mika-shop'.length);
  if (p.endsWith('/')) p += 'index.html';
  const file = path.normalize(path.join(ROOT, p));
  if (!file.startsWith(ROOT + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('404 not found'); }
    // no-store: every reload shows the latest saved file
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
});
server.listen(PORT, '127.0.0.1', () => console.log(`Preview (TEST database): http://localhost:${PORT}/mika-shop/   Stop with Ctrl+C.`));
// also answer on IPv6 loopback, in case "localhost" resolves to ::1
http.createServer(server.listeners('request')[0]).listen(PORT, '::1').on('error', () => {});
