// Serves Protect or Destroy files kept on Cloudflare instead of in the public GitHub repository:
// the game-ready character models (models/...) and the Godot web preview (preview/...).
// Files live in the KV namespace bound as FILES; upload.sh puts them there.
// A file stored as NAME.gz is sent as NAME with Content-Encoding: gzip (the browser unpacks it).
const TYPES = { html: 'text/html; charset=utf-8', js: 'text/javascript', wasm: 'application/wasm', pck: 'application/octet-stream',
  glb: 'model/gltf-binary', json: 'application/json', png: 'image/png', jpg: 'image/jpeg', mp4: 'video/mp4' };
const ALLOWED = [/^https:\/\/(www\.)?gravitatepictures\.com$/, /^https:\/\/[a-z0-9-]+\.gravitatepictures\.workers\.dev$/,
  /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin');
    const cors = origin && ALLOWED.some(re => re.test(origin)) ? { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin' } : {};
    if (request.method === 'OPTIONS') return new Response(null, { headers: { ...cors, 'Access-Control-Allow-Methods': 'GET' } });
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405 });
    let key = decodeURIComponent(url.pathname.slice(1));
    if (key === '' || key === 'preview' || key.endsWith('/')) key = (key || 'preview/') .replace(/\/?$/, '/') + 'index.html';
    if (key.includes('..')) return new Response('Not found', { status: 404 });
    const type = TYPES[key.split('.').pop()] || 'application/octet-stream';
    const headers = { ...cors, 'Content-Type': type, 'Cache-Control': 'public, max-age=300' };
    let body = await env.FILES.get(key, 'stream');
    if (!body) {
      body = await env.FILES.get(key + '.gz', 'stream');
      if (!body) return new Response('Not found', { status: 404, headers: cors });
      headers['Content-Encoding'] = 'gzip';
      return new Response(request.method === 'HEAD' ? null : body, { headers, encodeBody: 'manual' });
    }
    return new Response(request.method === 'HEAD' ? null : body, { headers });
  },
};
