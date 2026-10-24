// Runs only after an explicit experimental capture request, in the main frame.
(() => {
  'use strict';
  if (location.protocol !== 'https:' || location.hostname !== 'gjt.noc.vmc.navblue.cloud' || window !== top) return;
  if (window.__RAIDONativeExperiment) window.__RAIDONativeExperiment.stop();
  const token = '__CAPTURE_TOKEN__';
  const limit = 4 * 1024 * 1024;
  const bytes = value => new TextEncoder().encode(value).byteLength;
  const eligible = (raw, method, body) => {
    try {
      const u = new URL(raw, location.href);
      if (u.origin !== location.origin || u.username || u.password || u.search || u.hash ||
          /%/.test(u.pathname) || !/\/GetRoster$/i.test(u.pathname) ||
          String(method).toUpperCase() !== 'POST' || typeof body !== 'string' || bytes(body) > 4096) return null;
      const p = JSON.parse(body);
      if (!p || Array.isArray(p) || Object.keys(p).sort().join(',') !== 'hrId,month,year') return null;
      return {url:u.href, requestBody:body};
    } catch (_) { return null; }
  };
  let stopped = false, delivered = false;
  const send = (request, status, body) => {
    if (stopped || delivered || !request || status !== 200 || typeof body !== 'string' || bytes(body) > limit) return;
    try {
      const p = JSON.parse(body);
      if (!p || typeof p !== 'object') return;
      window.webkit.messageHandlers.nativeRAIDOProbe.postMessage({token, ...request, responseBody:body});
      delivered = true;
    } catch (_) {}
  };
  const originalFetch = window.fetch;
  const wrappedFetch = function(input, init) {
    // Do not read Request streams or alter the original request/response.
    const raw = typeof input === 'string' || input instanceof URL ? String(input) : input.url;
    const request = eligible(raw, (init && init.method) || (input && input.method) || 'GET', init && init.body);
    const result = originalFetch.apply(this, arguments);
    if (request) result.then(response => {
      if (stopped || delivered || response.status !== 200 || response.url !== request.url) return;
      const length = Number(response.headers.get('content-length'));
      if (length > limit) return;
      // Bound the clone while streaming; the page consumes its original normally.
      const clone = response.clone();
      if (!clone.body) return;
      const reader = clone.body.getReader(), chunks = []; let total = 0;
      const read = async () => {
        try {
          while (!stopped && !delivered) {
            const part = await reader.read();
            if (part.done) {
              const merged = new Uint8Array(total); let offset = 0;
              for (const c of chunks) { merged.set(c, offset); offset += c.byteLength; }
              send(request, response.status, new TextDecoder().decode(merged)); return;
            }
            total += part.value.byteLength;
            if (total > limit) return;
            chunks.push(part.value);
          }
        } finally { try { await reader.cancel(); } catch (_) {} }
      };
      read().catch(() => {});
    }).catch(() => {});
    return result;
  };
  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  const requests = new WeakMap();
  const wrappedOpen = function(method, url) {
    const result = originalOpen.apply(this, arguments);
    requests.set(this, {method, url});
    return result;
  };
  const wrappedSend = function(body) {
    const meta = requests.get(this), request = meta && eligible(meta.url, meta.method, body);
    if (request) this.addEventListener('load', () => {
      if (stopped || delivered || this.responseURL !== request.url || this.status !== 200) return;
      try {
        const value = this.responseType === 'json' ? JSON.stringify(this.response) :
          (this.responseType === '' || this.responseType === 'text' ? this.responseText : null);
        send(request, this.status, value);
      } catch (_) {}
    }, {once:true});
    return originalSend.apply(this, arguments);
  };
  if (typeof originalFetch === 'function') window.fetch = wrappedFetch;
  XMLHttpRequest.prototype.open = wrappedOpen;
  XMLHttpRequest.prototype.send = wrappedSend;
  window.__RAIDONativeExperiment = Object.freeze({stop() {
    stopped = true;
    if (window.fetch === wrappedFetch) window.fetch = originalFetch;
    if (XMLHttpRequest.prototype.open === wrappedOpen) XMLHttpRequest.prototype.open = originalOpen;
    if (XMLHttpRequest.prototype.send === wrappedSend) XMLHttpRequest.prototype.send = originalSend;
    delete window.__RAIDONativeExperiment;
  }});
})();
