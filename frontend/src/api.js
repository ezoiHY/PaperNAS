export const API_PREFIX = '/api/v2';

export function requestID() {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('');
}

export function localPath(path) {
  if (typeof path !== 'string' || !/^\/api\/v2\//.test(path) || /[\\\s#]/.test(path)) {
    throw new Error('This resource is outside the Paper NAS API.');
  }
  const parsed = new URL(path, 'https://papernas.invalid');
  if (parsed.origin !== 'https://papernas.invalid' || !parsed.pathname.startsWith(API_PREFIX + '/')) {
    throw new Error('This resource is outside the Paper NAS API.');
  }
  return parsed.pathname + parsed.search;
}

export class APIError extends Error {
  constructor(message, status = 0, data = {}) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

export class API {
  constructor(fetcher = (...args) => fetch(...args)) {
    this.fetcher = fetcher;
    this.token = '';
    this.deviceID = '';
    this.pending = new Map();
    this.fileIDs = new WeakMap();
  }

  async call(path, { method = 'GET', body, form, raw = false, signal } = {}) {
    path = localPath(path.startsWith('/api/') ? path : API_PREFIX + path);
    const headers = { Accept: raw ? '*/*' : 'application/json' };
    if (this.token) headers.Authorization = 'Bearer ' + this.token;
    const changing = !['GET', 'HEAD'].includes(method);
    const sensitive = path.includes('/auth/') || path.endsWith('/model/key');
    const formIdentity = form && Array.from(form.entries(), ([name, value]) => {
      if (typeof value === 'string') return [name, value];
      if (!this.fileIDs.has(value)) this.fileIDs.set(value, requestID());
      return [name, this.fileIDs.get(value)];
    });
    const identity = changing && !sensitive ? method + path + JSON.stringify(formIdentity || body || null) : null;
    if (changing) {
      // An explicit retry of an uncertain mutation reuses its identity. Never
      // automatically resend model work, and never persist secret request bodies.
      const key = (identity && this.pending.get(identity)) || requestID();
      headers['Idempotency-Key'] = key;
      if (identity) this.pending.set(identity, key);
    }
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let response;
    try {
      response = await this.fetcher(path, {
        method, headers, body: form || (body === undefined ? undefined : JSON.stringify(body)),
        credentials: 'omit', cache: 'no-store', redirect: 'error', signal,
      });
    } catch (error) {
      if (error.name === 'AbortError') throw error;
      throw new APIError(changing
        ? 'The connection stopped before the result was confirmed. Check Tasks or refresh the record before trying again.'
        : 'Cannot reach the server. Check the connection and try again.');
    }
    if (!response.ok) {
      let data = {};
      try { data = await response.json(); } catch { /* A proxy can return a non-JSON error. */ }
      if (identity && response.status < 500) this.pending.delete(identity);
      const details = data.fields?.map(f => f.path.slice(1).join('.') + ': ' + f.message).join('; ');
      const conflict = data.type === 'urn:papernas:error:revision_conflict' || data.code === 'revision_conflict';
      const message = response.status === 409 && conflict
        ? 'This record changed on another device. Your input is preserved. Close this form, refresh, and apply your changes to the latest version.'
        : details || data.detail || data.error || `Server returned HTTP ${response.status}.`;
      throw new APIError(message, response.status, data);
    }
    if (identity) this.pending.delete(identity);
    if (raw) return response;
    if (response.status === 204) return null;
    return response.json();
  }

  async connect(key, deviceName) {
    const result = await this.call('/auth/devices', {
      method: 'POST', body: { access_key: key, device_name: deviceName },
    });
    this.token = result.device.token;
    this.deviceID = result.device.id;
    return result;
  }
}

export function safeExternalURL(value) {
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

export function fileName(value, extension) {
  return (String(value || 'paper').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-').slice(0, 120).trim() || 'paper') + '.' + extension;
}
