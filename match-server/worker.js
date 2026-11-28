// Protect or Destroy match server.
//
// A small signalling server that speaks the PeerJS server protocol, so the game's PeerJS
// client can use it in place of the free public PeerJS server. Every player connects to one
// Durable Object (the lobby), so two phones can always find each other. It only passes the
// short connection set-up messages between players; the match itself runs phone to phone.
//
// Differences from the public server, made for phones:
// - A player who drops off briefly (a phone switching apps) keeps their place for a few
//   seconds: messages for them are held and delivered when they come back.
// - A connection that has gone silent is treated as gone, so the same player can take their
//   match code back straight away instead of being told it is taken.

import { DurableObject } from 'cloudflare:workers';

const ALLOWED_ORIGINS = [/^https:\/\/gravitatepictures\.com$/, /^https:\/\/www\.gravitatepictures\.com$/,
  /^http:\/\/localhost(:\d+)?$/, /^http:\/\/127\.0\.0\.1(:\d+)?$/];
const HOLD_MS = 5000;      // how long messages for an absent player are held
const SILENT_MS = 12000;   // a connection with no message for this long counts as gone (clients ping every 5 s)
const RELAYED = ['OFFER', 'ANSWER', 'CANDIDATE', 'LEAVE', 'EXPIRE'];
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

function originAllowed(request) {
  const origin = request.headers.get('Origin');
  return !origin || ALLOWED_ORIGINS.some(re => re.test(origin));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin');
    const cors = { 'Access-Control-Allow-Origin': origin && originAllowed(request) ? origin : 'https://gravitatepictures.com',
      'Vary': 'Origin', 'Cache-Control': 'no-store' };
    if (!originAllowed(request)) return new Response('Forbidden', { status: 403, headers: cors });
    if (url.pathname === '/' || url.pathname === '/peerjs/') return new Response('Protect or Destroy match server', { headers: cors });
    if (url.pathname === '/peerjs/id') return new Response(crypto.randomUUID(), { headers: { ...cors, 'Content-Type': 'text/plain' } });
    if (url.pathname === '/peerjs/peers') return new Response('[]', { headers: { ...cors, 'Content-Type': 'application/json' } });
    if (url.pathname === '/peerjs' && request.headers.get('Upgrade') === 'websocket') {
      return env.LOBBY.get(env.LOBBY.idFromName('main')).fetch(request);
    }
    return new Response('Not found', { status: 404, headers: cors });
  },
};

export class Lobby extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.held = new Map();          // player id -> [{ msg, at }]
    this.timer = null;
  }

  // The live connection for a player id, or null.
  find(id) {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets(id)) {
      const a = ws.deserializeAttachment();
      if (a && a.id === id && !a.gone && ws.readyState === 1 && now - a.seen < SILENT_MS) return ws;
    }
    return null;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const id = url.searchParams.get('id') || '', token = url.searchParams.get('token') || '';
    const [client, server] = Object.values(new WebSocketPair());
    if (!ID_RE.test(id) || !token) {
      server.accept();
      server.send(JSON.stringify({ type: 'ERROR', payload: { msg: 'Missing or invalid id or token' } }));
      server.close(1008, 'invalid');
      return new Response(null, { status: 101, webSocket: client });
    }
    const now = Date.now();
    for (const old of this.ctx.getWebSockets(id)) {
      const a = old.deserializeAttachment();
      if (!a || a.gone) continue;
      const live = old.readyState === 1 && now - a.seen < SILENT_MS;
      if (live && a.token !== token) {           // someone else holds this id
        server.accept();
        server.send(JSON.stringify({ type: 'ID-TAKEN', payload: { msg: 'ID is taken' } }));
        server.close(1000, 'taken');
        return new Response(null, { status: 101, webSocket: client });
      }
      a.gone = true;                              // the same player reconnecting, or a dead connection
      old.serializeAttachment(a);
      try { old.close(1000, 'replaced'); } catch (e) { /* already closed */ }
    }
    this.ctx.acceptWebSocket(server, [id]);
    server.serializeAttachment({ id, token, seen: now, gone: false });
    server.send(JSON.stringify({ type: 'OPEN' }));
    const waiting = this.held.get(id);            // messages that arrived while this player was away
    if (waiting) {
      this.held.delete(id);
      for (const h of waiting) { try { server.send(JSON.stringify(h.msg)); } catch (e) { /* closed again */ } }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, data) {
    const a = ws.deserializeAttachment();
    if (!a || a.gone) return;
    a.seen = Date.now();
    ws.serializeAttachment(a);
    let msg;
    try { msg = JSON.parse(typeof data === 'string' ? data : new TextDecoder().decode(data)); } catch (e) { return; }
    if (!msg || !RELAYED.includes(msg.type) || typeof msg.dst !== 'string' || !ID_RE.test(msg.dst)) return;
    const out = { type: msg.type, src: a.id, dst: msg.dst, payload: msg.payload };
    const to = this.find(msg.dst);
    if (to) {
      try { to.send(JSON.stringify(out)); return; } catch (e) { /* fall through and hold it */ }
    }
    if (msg.type === 'LEAVE' || msg.type === 'EXPIRE') return;
    const list = this.held.get(msg.dst) || [];
    if (list.length < 200) list.push({ msg: out, at: Date.now() });
    this.held.set(msg.dst, list);
    this.scheduleExpiry();
  }

  // Messages held too long: tell each sender the player could not be reached (PeerJS shows "peer-unavailable").
  scheduleExpiry() {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      const now = Date.now(), told = new Set();
      for (const [dst, list] of this.held) {
        const keep = [];
        for (const h of list) {
          if (now - h.at < HOLD_MS) { keep.push(h); continue; }
          const key = h.msg.src + '>' + dst;
          if (h.msg.type === 'OFFER' && !told.has(key)) {
            told.add(key);
            const from = this.find(h.msg.src);
            if (from) { try { from.send(JSON.stringify({ type: 'EXPIRE', src: dst, dst: h.msg.src })); } catch (e) { /* gone */ } }
          }
        }
        if (keep.length) this.held.set(dst, keep); else this.held.delete(dst);
      }
      if (this.held.size) this.scheduleExpiry();
    }, 1000);
  }

  async webSocketClose(ws) {
    const a = ws.deserializeAttachment();
    if (a && !a.gone) { a.gone = true; ws.serializeAttachment(a); }
  }

  async webSocketError(ws) { await this.webSocketClose(ws); }
}
