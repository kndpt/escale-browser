  // Part of the extension shim, after shim.js (ExtensionShims.parts):
  // how the rest reaches the browser — native calls, callbacks and lastError.

  // WebKit's runtime answers `lastError` itself, whatever is set on it, so
  // a callback never saw an error the shim reported; nor can `chrome.runtime`
  // be replaced, WebKit's `chrome` answering that itself too. So the
  // extension's pages and worker read the `chrome` global as a proxy whose
  // `runtime` answers `lastError` while one is reported, and calls WebKit's
  // methods on WebKit's own object. Every other namespace is WebKit's own,
  // and so is `browser`, which WebKit delivers events through: proxied too,
  // nothing reached the extension any more.
  let reported = null, proxy = null;
  if (!inContent && runtime) {
    const bound = new WeakMap();
    proxy = new Proxy(runtime, {
      get(target, key) {
        if (key === "lastError" && reported) return reported;
        const value = Reflect.get(target, key);
        if (typeof value !== "function") return value;
        if (!bound.has(value)) bound.set(value, value.bind(target));
        return bound.get(value);
      },
    });
    const api = new Proxy(chrome, { get: (target, key) => key === "runtime" ? proxy : Reflect.get(target, key) });
    shown = (v) => v === chrome ? api : v;
  }
  const withLastError = (error, callback) => {
    reported = { message: String(error && error.message || error) };
    try { callback(); } finally { reported = null; }
  };
  // Whether a tab is in the window in front. With one set of extensions for
  // every Space each Space is a window, and Escale counts a tab's place in
  // the row in the one on screen (Extensions.visibleTabs): an index from
  // another window would name another tab.
  const inFront = (tab) => chrome.windows && typeof chrome.windows.getLastFocused === "function"
    ? chrome.windows.getLastFocused().then((w) => !w || w.id === tab.windowId, () => true)
    : Promise.resolve(true);
  const native = (api, args) =>
    runtime.sendNativeMessage("escale", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
      .then((reply) => {
        if (reply && reply.error) throw new Error(reply.error);
        return reply ? reply.value : undefined;
      });
  // Chrome's APIs take a callback last, or return a promise without one.
  const call = (api) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const promise = native(api, args);
    if (!callback) return promise;
    promise.then((value) => callback(value), (error) => withLastError(error, callback));
  };
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f),
      hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
      listeners,
    };
  };
