const TOKEN_KEY = 'starwatch_token';

export class APIError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

export function bootstrapToken() {
  const url = new URL(window.location.href);
  const queryToken = url.searchParams.get('token');
  if (queryToken) {
    sessionStorage.setItem(TOKEN_KEY, queryToken);
    url.searchParams.delete('token');
    history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  }
  return queryToken || sessionStorage.getItem(TOKEN_KEY) || '';
}

export function storeToken(token) {
  if (token) sessionStorage.setItem(TOKEN_KEY, token);
  else sessionStorage.removeItem(TOKEN_KEY);
}

async function errorMessage(response) {
  const text = (await response.text()).trim();
  try { return JSON.parse(text).error || text || response.statusText; } catch (_) { return text || response.statusText; }
}

export async function apiFetch(token, path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (token) headers.set('Authorization', `Bearer ${token}`);
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  const response = await fetch(path, {...options, headers});
  if (!response.ok) throw new APIError(await errorMessage(response), response.status);
  if (response.status === 204) return null;
  return response.json();
}

export const getHistory = (token, series, span, signal) =>
  apiFetch(token, `/api/history?series=${encodeURIComponent(series)}&span=${encodeURIComponent(span)}`, {signal});

export class LiveClient {
  constructor({token, onFrame, onStatus, onUnauthorized, poll}) {
    Object.assign(this, {token, onFrame, onStatus, onUnauthorized, poll});
    this.stopped = false;
    this.backoff = 1000;
  }

  start() { this.connect(); }

  stop() {
    this.stopped = true;
    clearTimeout(this.retryTimer);
    clearInterval(this.pollTimer);
    this.socket?.close();
  }

  connect() {
    if (this.stopped || !this.token) return;
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.socket = new WebSocket(`${scheme}//${location.host}/api/ws?token=${encodeURIComponent(this.token)}`);
    this.socket.onopen = () => {
      this.backoff = 1000;
      clearInterval(this.pollTimer);
      this.pollTimer = null;
      this.onStatus?.('live');
    };
    this.socket.onmessage = event => {
      try { this.onFrame?.(JSON.parse(event.data)); } catch (error) { console.warn('Starwatch frame ignored', error); }
    };
    this.socket.onclose = event => {
      if (this.stopped) return;
      if (event.code === 1008) this.onUnauthorized?.();
      this.beginPolling();
      this.retryTimer = setTimeout(() => this.connect(), this.backoff);
      this.backoff = Math.min(30000, this.backoff * 2);
    };
    this.socket.onerror = () => this.socket?.close();
  }

  beginPolling() {
    this.onStatus?.('polling');
    if (this.pollTimer) return;
    const tick = async () => {
      try { this.onFrame?.({snapshot: await this.poll()}); }
      catch (error) { if (error.status === 401) this.onUnauthorized?.(); }
    };
    tick();
    this.pollTimer = setInterval(tick, 2000);
  }
}
