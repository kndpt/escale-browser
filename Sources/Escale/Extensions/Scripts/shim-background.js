  // Part of the extension shim (ExtensionShims.parts): the background's
  // start — install reason and late listeners — and the last members.

  // WebKit says "install" again when an extension is taken up afresh in
  // the same session — after a Reload, or a worker brought back — where
  // Chrome says "update"; extensions open their welcome page on
  // "install". The first one of a session is marked, and any later one
  // told as the update it is.
  if (background && runtime.onInstalled && typeof runtime.onInstalled.addListener === "function") {
    let decided = null;
    const seenBefore = () => decided || (decided = native("background.loadedBefore", []).then((v) => !!v, () => false));
    const add = runtime.onInstalled.addListener.bind(runtime.onInstalled);
    const remove = runtime.onInstalled.removeListener.bind(runtime.onInstalled);
    const wrapped = new Map();
    put(runtime.onInstalled, "addListener", (listener) => {
      const w = (details) => {
        if (!details || details.reason !== "install") return listener(details);
        seenBefore().then((seen) => listener(seen ? { ...details, reason: "update", previousVersion: runtime.getManifest().version } : details));
      };
      wrapped.set(listener, w);
      return add(w);
    });
    put(runtime.onInstalled, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
    put(runtime.onInstalled, "hasListener", (listener) => wrapped.has(listener));
  }

  // A worker may add listeners only while it starts; WebKit throws for
  // one added later, where Chrome takes it. So for every event this
  // extension's code mentions, the worker has one listener of WebKit's
  // from the start, and a late one joins the list behind it. Events it
  // never mentions still take late listeners without throwing — they
  // just aren't heard. (Request events are left alone: a listener for
  // all of them would wake the worker for every request.)
  if (background) {
    const mentioned = new Set(__ESCALE_EVENTS__);
    for (const space of Object.keys(chrome)) {
      if (space === "webRequest") continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const key of names) {
        if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
        let target; try { target = ns[key]; } catch (e) { continue; }
        if (!target || typeof target.addListener !== "function" || target.listeners) continue;
        const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
        const late = new Set();
        if (mentioned.has(space + "." + key)) {
          try {
            add(function (...args) {
              let answer;
              for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
              return answer;
            });
          } catch (e) {}
        }
        put(target, "addListener", (listener, ...rest) => {
          try { return add(listener, ...rest); }
          catch (e) { if (/startup/i.test(String(e && e.message))) late.add(listener); else throw e; }
        });
        put(target, "removeListener", (listener) => { late.delete(listener); try { remove(listener); } catch (e) {} });
      }
    }
  }

  // Members of namespaces WebKit has.
  if (chrome.i18n && !chrome.i18n.detectLanguage) put(chrome.i18n, "detectLanguage", call("i18n.detectLanguage"));
  if (runtime && !runtime.getContexts) put(runtime, "getContexts", call("runtime.getContexts"));
