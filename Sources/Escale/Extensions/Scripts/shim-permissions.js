  // Part of the extension shim (ExtensionShims.parts): permissions, WebKit's
  // and the ones Escale answers itself.

  // Permissions. WebKit knows its own and throws on any other name,
  // where Chrome answers false. The ones Escale answers itself are
  // Escale's to grant: those a manifest names are granted, optional
  // ones are asked for.
  if (chrome.permissions) {
    const webkit = new Set(["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
      "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
      "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]);
    const ours = new Set(["bookmarks", "history", "downloads", "downloads.open", "downloads.shelf", "downloads.ui",
      "tabGroups", "sidePanel", "offscreen", "notifications", "tts", "fontSettings", "management", "identity",
      "identity.email", "idle", "power", "privacy", "browsingData", "sessions", "topSites", "search", "system.cpu",
      "system.memory", "system.storage", "system.display", "readingList", "contentSettings", "proxy", "favicon",
      "clipboardRead", "geolocation", "userScripts"]);
    const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
    const declared = new Set(manifest.permissions || []);
    const split = (list = []) => ({
      theirs: list.filter((p) => webkit.has(p)), mine: list.filter((p) => ours.has(p)),
      unknown: list.filter((p) => !webkit.has(p) && !ours.has(p)),
    });
    const p = chrome.permissions;
    const contains = p.contains.bind(p), request = p.request.bind(p), getAll = p.getAll.bind(p), remove = p.remove.bind(p);
    const granted = () => native("permissions.granted", []).then((list) => new Set([...declared, ...(list || [])]));
    const withCb = (f) => (arg, callback) => {
      const pr = f(arg || {});
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    put(p, "contains", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length) return false;
      if (mine.length) { const have = await granted(); if (!mine.every((m) => have.has(m))) return false; }
      return theirs.length || origins.length ? contains({ permissions: theirs, origins }) : true;
    }));
    put(p, "request", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length) return false;
      if (mine.length) {
        const have = await granted();
        const missing = mine.filter((m) => !have.has(m));
        if (missing.length && !(await native("permissions.request", [missing]))) return false;
      }
      return theirs.length || origins.length ? request({ permissions: theirs, origins }) : true;
    }));
    put(p, "getAll", (callback) => {
      const pr = (async () => {
        const all = await getAll();
        const have = await granted();
        return { ...all, permissions: [...new Set([...(all.permissions || []), ...[...have].filter((m) => ours.has(m))])] };
      })();
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    });
    put(p, "remove", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine } = split(permissions);
      if (mine.length) await native("permissions.remove", [mine]);
      return theirs.length || origins.length ? remove({ permissions: theirs, origins }) : true;
    }));
  }
