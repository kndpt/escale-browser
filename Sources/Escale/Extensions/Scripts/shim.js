// Chrome's extension APIs, mended and filled in on WebKit: put first in an
// extension's worker, pages and content scripts (ExtensionShims.prepare).
// One function in several files, assembled in order (ExtensionShims.parts);
// content scripts get only this first one.
(() => {
  const root = globalThis;
  // Taken now, not looked up at each use: a sandbox that later locks
  // the globals away (MetaMask's LavaMoat) would break the shim's own
  // code that needs them — every fetch of a Request, every import.
  const { URL, FileReader, Response, Blob, File, DOMException, HTMLImageElement, HTMLAnchorElement, Element } = root;
  // WebKit reverted `requestIdleCallback` after a page-load regression
  // (bug 287681), leaving Proton Pass's form detection without it.
  const nativeIdle = typeof root.requestIdleCallback === "function"
    ? root.requestIdleCallback.bind(root) : null;
  const nativeCancelIdle = typeof root.cancelIdleCallback === "function"
    ? root.cancelIdleCallback.bind(root) : null;
  if (!nativeIdle || !nativeCancelIdle) {
    const idle = new Map();
    let idleId = 0;
    root.requestIdleCallback = (callback, options) => {
      const id = ++idleId;
      if (nativeIdle) {
        const nativeId = nativeIdle((deadline) => {
          if (!idle.delete(id)) return;
          callback(deadline);
        }, options);
        idle.set(id, { nativeId });
      } else {
        // Let the requesting script finish first. Chrome's maximum
        // idle deadline is 50 ms; this fallback uses the full budget.
        const timer = setTimeout(() => {
          if (!idle.delete(id)) return;
          const start = Date.now();
          callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
        }, 1);
        idle.set(id, { timer });
      }
      return id;
    };
    root.cancelIdleCallback = (id) => {
      const request = idle.get(id);
      if (request === undefined) {
        if (nativeCancelIdle) nativeCancelIdle(id);
        return;
      }
      idle.delete(id);
      if (request.timer !== undefined) clearTimeout(request.timer);
      else if (nativeCancelIdle) nativeCancelIdle(request.nativeId);
    };
  }
  // Keep the first credentials container alive so extension hooks
  // survive WebKit replacing an unreferenced container.
  const credentials = root.navigator && root.navigator.credentials;
  if (credentials && !Object.prototype.hasOwnProperty.call(root, "__escaleCredentials")) {
    Object.defineProperty(root, "__escaleCredentials", { value: credentials });
  }
  const chrome = root.chrome || root.browser;
  if (!chrome || root.__escaleShim) return;
  Object.defineProperty(root, "__escaleShim", { value: true });
  // WebKit finds a page's extension APIs through the `chrome` and
  // `browser` globals when it delivers an event. A sandbox that locks
  // every global away (MetaMask's LavaMoat) cuts it off: nothing arrives
  // any more. Made fixed accessors, they can't be taken away, and code
  // that assigns its own polyfill to them still can. What they show is
  // WebKit's object, but for `chrome` once the shim says otherwise (`shown`,
  // see lastError); events come in through `browser`, which stays WebKit's.
  let shown = (v) => v;
  for (const key of ["browser", "chrome"]) {
    const d = Object.getOwnPropertyDescriptor(root, key);
    if (!d || !d.configurable) continue;
    let value = root[key];
    // A replacement that hides the APIs — a Proxy some extensions put
    // there to keep them from other code (Proton Pass) — would hide them
    // from WebKit too, and nothing would reach the extension again. A
    // replacement that still carries them is taken.
    const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
    try { Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => key === "chrome" ? shown(value) : value, set: (v) => { if (carries(v)) value = v; } }); } catch (e) {}
  }
  // On a web page this is a content script: only Chrome's behaviour is
  // mended there, no API that Chrome doesn't give content scripts either.
  const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
  // One of the extension's pages in a frame of a website — Vimium's bar,
  // the list iCloud Passwords opens under a field. WebKit runs it in the
  // website's process, which it trusts with no more than a content
  // script: a single call to tabs, windows, scripting… and WebKit takes
  // the process for compromised and ends it. The page reloads, and a
  // frame that makes the call as it loads reloads it for ever. Chrome
  // gives such a frame everything, so here the worker makes those calls
  // for it (see `__escaleCall`).
  const embedded = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
    try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
    try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
  })();
  const runtime = chrome.runtime;

  // WebKit's objects are kept — WebKit finds an extension's listeners
  // through them, and a replacement would hide them. Members are set on
  // them instead: a method lives on the prototype, so an own property of
  // the same name takes its place.
  // WebKit's namespace and event objects are wrappers it doesn't keep
  // alive: once no script holds one, it is collected, and the next
  // `chrome.tabs` is a fresh object without what was set on it. So every
  // object touched here is held for good.
  const kept = new Set();
  try { Object.defineProperty(root, "__escaleKept", { value: kept }); } catch (e) {}
  const put = (target, key, value) => {
    if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
    try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
    catch (e) { try { target[key] = value; } catch (e2) {} }
  };
  // Held from the start, before the extension's own code runs — its
  // polyfills set things on these objects too.
  const spaces = new Set(Object.keys(chrome));
  for (let o = Object.getPrototypeOf(chrome); o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => spaces.add(k));
  for (const space of spaces) {
    let ns; try { ns = chrome[space]; } catch (e) { continue; }
    if (!ns || typeof ns !== "object") continue;
    kept.add(ns);
    // And the same object every time it is asked for: WebKit can hand
    // out a fresh one, without what was set on the last.
    if (!Object.prototype.hasOwnProperty.call(chrome, space) || Object.getOwnPropertyDescriptor(chrome, space).get) {
      try { Object.defineProperty(chrome, space, { value: ns, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    }
    for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
      for (const key of Object.getOwnPropertyNames(o)) {
        if (!/^on[A-Z]/.test(key)) continue;
        try { const ev = ns[key]; if (ev && typeof ev === "object") kept.add(ev); } catch (e) {}
      }
    }
    for (const sub of ["local", "sync", "session", "managed"]) { try { if (ns[sub] && typeof ns[sub] === "object") kept.add(ns[sub]); } catch (e) {} }
  }
  // Content scripts stop here, and get only what is above
  // (ExtensionShims.content): what follows is for the extension's own
  // worker and pages.
  if (inContent) return;
