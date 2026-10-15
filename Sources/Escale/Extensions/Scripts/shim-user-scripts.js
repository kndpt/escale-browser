  // Part of the extension shim (ExtensionShims.parts): chrome.userScripts.

  // chrome.userScripts — what Tampermonkey, Violentmonkey and the
  // advanced rules of the ad blockers run on — carried out through
  // WebKit's registered content scripts. The browser writes each script
  // into a file of the extension's (content scripts come from files),
  // wrapped so the globs Chrome takes are honoured and, for Chrome's
  // USER_SCRIPT world, so its messages reach onUserScriptMessage rather
  // than the extension's own onMessage. The list lives with the browser,
  // and is registered again whenever the worker starts.
  const scripting = chrome.scripting;
  const wantsUserScripts = (() => { try { return (runtime.getManifest().permissions || []).includes("userScripts"); } catch (e) { return false; } })();
  if (!chrome.userScripts && wantsUserScripts && scripting && typeof scripting.registerContentScripts === "function") {
    const tag = "escale-us-";
    const content = async (script) => ({
      id: tag + script.id,
      matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
      excludeMatches: script.excludeMatches || [],
      js: [await native("userScripts.file", [script])],
      runAt: script.runAt || "document_idle",
      allFrames: !!script.allFrames,
      world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
      persistAcrossSessions: false,
    });
    const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
    const list = () => native("userScripts.list", []).then((l) => l || []);
    const save = (l) => native("userScripts.save", [l]);
    const sync = async () => {
      const want = await list();
      const have = new Set((await registered()).map((s) => s.id));
      const missing = want.filter((s) => !have.has(tag + s.id));
      if (!missing.length) return;
      const scripts = await Promise.all(missing.map(content));
      // Two starts of the worker racing each other: the later one takes
      // the registration over.
      await scripting.registerContentScripts(scripts).catch(async (e) => {
        if (!/duplicate/i.test(String(e && e.message))) throw e;
        await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
        await scripting.registerContentScripts(scripts);
      });
    };
    const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
    const api = {
      register: async (scripts) => {
        const l = await list();
        for (const s of scripts) if (l.some((o) => o.id === s.id)) throw new Error("Duplicate script id '" + s.id + "'");
        await scripting.registerContentScripts(await Promise.all(scripts.map(content)));
        await save([...l, ...scripts]);
      },
      update: async (scripts) => {
        const l = await list();
        const merged = scripts.map((s) => {
          const old = l.find((o) => o.id === s.id);
          if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
          return { ...old, ...s };
        });
        await scripting.unregisterContentScripts({ ids: merged.map((s) => tag + s.id) }).catch(() => {});
        await scripting.registerContentScripts(await Promise.all(merged.map(content)));
        await save(l.map((o) => merged.find((m) => m.id === o.id) || o));
      },
      unregister: async (filter) => {
        const l = await list();
        const gone = pick(filter, l);
        const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
        if (ids.length) await scripting.unregisterContentScripts({ ids });
        await save(l.filter((o) => !gone.includes(o)));
      },
      getScripts: async (filter) => pick(filter, await list()),
      configureWorld: (properties) => native("userScripts.world", [properties || {}]),
      getWorldConfigurations: () => native("userScripts.worlds", []),
      resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
      execute: async (injection) => {
        const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
        return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
          injectImmediately: !!injection.injectImmediately });
      },
    };
    const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    }]));
    put2("userScripts", { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } });
    if (background) sync().catch((e) => { try { native("debug.error", ["userScripts: " + e.message]).catch(() => {}); } catch (x) {} });

    // Messages from the USER_SCRIPT world come tagged (see the file's
    // wrapper); they go to onUserScriptMessage and onUserScriptConnect.
    const onMessage = runtime.onUserScriptMessage, onConnect = runtime.onUserScriptConnect;
    root.__escaleUserScriptMessage = (message, sender, respond) => {
      let keep = false;
      for (const f of [...onMessage.listeners]) {
        const r = f(message, sender, respond);
        if (r === true) keep = true;
        else if (r && typeof r.then === "function") { keep = true; r.then(respond); }
      }
      return keep;
    };
    if (runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
      const marker = "escale-us:";
      const add = runtime.onConnect.addListener.bind(runtime.onConnect);
      const remove = runtime.onConnect.removeListener.bind(runtime.onConnect);
      const wrapped = new Map();
      try {
        add((port) => {
          if (!String(port.name).startsWith(marker)) return;
          const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
          for (const f of [...onConnect.listeners]) f(view);
        });
      } catch (e) {}
      put(runtime.onConnect, "addListener", (listener) => {
        const w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
        wrapped.set(listener, w);
        return add(w);
      });
      put(runtime.onConnect, "removeListener", (listener) => { const w = wrapped.get(listener); if (w) { wrapped.delete(listener); remove(w); } });
    }
  }
