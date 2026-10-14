  // Part of the extension shim (ExtensionShims.parts): the namespaces
  // WebKit has, made to behave as Chrome's.

  // WebKit serves an extension's .wasm files without the application/wasm
  // type, so compiling one as it streams in fails. Most code falls back
  // to fetching it whole, with a warning; some has no fallback and
  // stops. The whole file is what they get from the start.
  if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
    const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
    const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
    WebAssembly.instantiateStreaming = async (source, imports) => {
      const response = await source;
      return own(response) ? WebAssembly.instantiate(await response.arrayBuffer(), imports) : instantiate(response, imports);
    };
    if (typeof WebAssembly.compileStreaming === "function") {
      const compile = WebAssembly.compileStreaming.bind(WebAssembly);
      WebAssembly.compileStreaming = async (source) => {
        const response = await source;
        return own(response) ? WebAssembly.compile(await response.arrayBuffer()) : compile(response);
      };
    }
  }

  // Members Chrome has on the namespaces WebKit has too, that WebKit
  // leaves out. Plenty are read at the top of a worker — an enum, an
  // event to listen to — where one missing member is a TypeError that
  // stops the whole worker before it has done anything.
  const fill = (name, members) => {
    const target = chrome[name];
    if (!target) return;
    for (const [key, value] of Object.entries(members)) {
      let there;
      try { there = target[key]; } catch (e) {}
      if (there === undefined) put(target, key, value);
    }
  };
  const resolve = (value) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const v = typeof value === "function" ? value(...args) : value;
    if (!callback) return Promise.resolve(v);
    setTimeout(() => callback(v));
  };
  const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
  const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
    "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
  fill("runtime", {
    onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
    onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
    requestUpdateCheck: (callback) => {
      if (typeof callback === "function") { setTimeout(() => callback("no_update", {})); return; }
      return Promise.resolve({ status: "no_update" });
    },
    restart: () => {}, restartAfterDelay: resolve(undefined),
    getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
    OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
    OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
    PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
    RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
    ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
      SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
  });
  // The popup Escale shows is a page of its own, known to WebKit as a
  // tab with no place in the row (no index). Chrome has no current
  // tab in a popup, and lists it among the popup views; extensions lay
  // themselves out by that (Bitwarden, Proton Pass: or else they fill
  // the window as if in a tab).
  if (typeof document !== "undefined") {
    // Known at once for the manifest's popup page — pages lay themselves
    // out before any answer can come back — and settled by what WebKit
    // says of the tab.
    let popup = (() => {
      try {
        const m = runtime.getManifest(), a = m.action || m.browser_action || {};
        return !!a.default_popup && new URL(a.default_popup, location.origin + "/").pathname === location.pathname;
      } catch (e) { return false; }
    })();
    // Not in a website's frame: never the popup, and asking costs the
    // worker a message for every frame the extension opens.
    if (!embedded && chrome.tabs && typeof chrome.tabs.getCurrent === "function") {
      const getCurrent = chrome.tabs.getCurrent.bind(chrome.tabs);
      const current = () => Promise.resolve(getCurrent()).then((t) => {
        if (t && !(t.index >= 0 && t.index < 1e6)) { popup = true; return undefined; }
        if (t) popup = false;
        return t;
      });
      current().catch(() => {});
      put(chrome.tabs, "getCurrent", (callback) => {
        const p = current();
        if (typeof callback !== "function") return p;
        p.then((t) => callback(t), (e) => withLastError(e, callback));
      });
    }
    if (chrome.extension && typeof chrome.extension.getViews === "function") {
      const extension = chrome.extension;
      const getViews = extension.getViews.bind(extension);
      const views = (properties = {}) => {
        let list = [...(getViews(properties) || [])];
        if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
        if (popup && (!properties.type || properties.type === "popup") && !list.includes(root)) list.push(root);
        return list;
      };
      put(extension, "getViews", views);
      // WebKit's getViews is read-only, and so is chrome.extension: both
      // ignore any redefinition without a word. The popup page's code
      // is then handed a `chrome` of its own, built on WebKit's, whose
      // extension namespace answers getViews and passes everything else
      // on (Malwarebytes lays itself out as a tab otherwise).
      if (popup && extension.getViews !== views) {
        const bound = new Map();
        const ownExtension = Object.create(extension);
        for (const key of Object.getOwnPropertyNames(extension)) {
          if (key === "getViews") continue;
          Object.defineProperty(ownExtension, key, { configurable: true, enumerable: true, get: () => {
            const v = extension[key];
            if (typeof v !== "function") return v;
            if (!bound.has(key)) bound.set(key, v.bind(extension));
            return bound.get(key);
          } });
        }
        Object.defineProperty(ownExtension, "getViews", { value: views, configurable: true, writable: true, enumerable: true });
        const ownChrome = Object.create(chrome);
        Object.defineProperty(ownChrome, "extension", { value: ownExtension, configurable: true, writable: true, enumerable: true });
        for (const key of ["chrome", "browser"]) {
          try { if (root[key] === chrome) root[key] = ownChrome; } catch (e) {}
        }
      }
    }
  }
  fill("extension", {
    getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
    sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
    getExtensionTabs: () => [], setUpdateUrlData: () => {},
  });
  fill("tabs", {
    TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
    WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    ZoomSettingsMode: enumOf("automatic", "manual", "disabled"),
    ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
    MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
    getZoomSettings: resolve({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 }),
    setZoomSettings: resolve(undefined), onZoomChange: event(),
    onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
    group: refuse("tabs.group"), ungroup: resolve(undefined),
    getSelected: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ active: true, currentWindow: true }).then((t) => f && f(t[0]));
    },
    getAllInWindow: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ currentWindow: true }).then((t) => f && f(t));
    },
  });
  if (chrome.tabs) {
    // Moving, sleeping and bringing forward tabs, by where they are in
    // the row — the one thing both sides agree on.
    const settle = () => new Promise((r) => setTimeout(r, 60));
    const byIndex = (api) => async (ids, extra) => {
      const out = [];
      for (const id of Array.isArray(ids) ? ids : [ids]) {
        const tab = await chrome.tabs.get(id);
        if (!(await inFront(tab))) throw new Error("This space is parked");
        await native(api, [tab.index, extra]);
        await settle();
        out.push(await chrome.tabs.get(id).catch(() => tab));
      }
      return Array.isArray(ids) ? out : out[0];
    };
    const withCallback = (f) => (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    fill("tabs", {
      move: withCallback(async (ids, props = {}) => {
        const list = Array.isArray(ids) ? ids : [ids];
        const out = [];
        let at = props.index ?? -1;
        for (const id of list) {
          out.push(await byIndex("tabs.move")(id, at));
          if (at !== -1) at++;
        }
        return Array.isArray(ids) ? out : out[0];
      }),
      discard: withCallback((id) => id === undefined
        ? chrome.tabs.query({ active: false, currentWindow: true }).then((t) => t[0] && byIndex("tabs.discard")(t[0].id))
        : byIndex("tabs.discard")(id)),
      highlight: withCallback(async (info = {}) => {
        const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
        await native("tabs.activate", [first]);
        await settle();
        return chrome.windows ? chrome.windows.getCurrent({ populate: true }) : undefined;
      }),
    });
  }
  fill("windows", {
    // Chrome's, and not WebKit's: an extension subscribing to it at
    // start — Session Buddy, inside a try — threw there and never
    // reached the rest, its button's listener included. Never fired:
    // a window's bounds are read when they are asked for.
    onBoundsChanged: event(),
    CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
  });
  fill("storage", {
    managed: { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() },
    AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
  });
  // Items built with Object.create(null) — Chrome stores them, WebKit
  // throws that an object is expected.
  for (const area of ["local", "sync", "session"]) {
    const store = chrome.storage && chrome.storage[area];
    if (!store || typeof store.set !== "function") continue;
    const set = store.set.bind(store);
    put(store, "set", (items, ...rest) => set(items && typeof items === "object" && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items, ...rest));
  }
  fill("scripting", {
    ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
    StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
  });
  // The popup an extension sets for its button, told to the browser too:
  // Escale opens a popup itself (see Extensions.press), and has to know
  // which page it is now.
  for (const name of ["action", "browserAction"]) {
    const a = chrome[name];
    if (!a || typeof a.setPopup !== "function") continue;
    const setPopup = a.setPopup.bind(a);
    put(a, "setPopup", (details = {}, callback) => {
      const tell = (index) => native("action.popup", [details.popup || "", index]).catch(() => {});
      if (typeof details.tabId === "number" && chrome.tabs) chrome.tabs.get(details.tabId).then((t) => inFront(t).then((yes) => yes && tell(t.index)), () => {});
      else tell(-1);
      return setPopup(details, callback);
    });
  }
  fill("action", {
    getUserSettings: resolve({ isOnToolbar: true }), onUserSettingsChanged: event(),
    setBadgeTextColor: resolve(undefined), getBadgeTextColor: resolve([255, 255, 255, 255]),
  });
  fill("webNavigation", {
    onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
    TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
      "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
    TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
  });
  fill("webRequest", {
    OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
    OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
    OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
    ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
    handlerBehaviorChanged: resolve(undefined), onActionIgnored: event(),
  });
  fill("declarativeNetRequest", {
    GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
    MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
    DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
    getAvailableStaticRuleCount: resolve(30000), getDisabledRuleIds: resolve([]), updateStaticRules: resolve(undefined),
    testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"), onRuleMatchedDebug: event(),
    RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
      MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
    ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
    DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
    RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
    UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
  });
  const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
    "launcher", "browser_action", "page_action", "action");
  fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
  fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });

  // Rules WebKit can't carry out — a header it doesn't know how to set,
  // say — are refused one by one, where Chrome would take them all. The
  // rest still go in: one rule Escale can't honour shouldn't cost an
  // extension every other rule, or its startup.
  const dnr = chrome.declarativeNetRequest;
  // Before WebKit sees them, rules are put the way it takes them: a
  // redirect to one of the extension's own files by path rather than by
  // address, and without the resource types it has no name for.
  const unknownTypes = new Set(["webtransport", "webbundle", "object"]);
  const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
  const mendRule = (rule) => {
    if (!rule || typeof rule !== "object") return rule;
    const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
    const redirect = r.action && r.action.redirect;
    if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
      r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
    }
    const c = r.condition;
    if (c && Array.isArray(c.resourceTypes)) {
      c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
      if (!c.resourceTypes.length) return null;
    }
    if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
    return r;
  };
  if (dnr && typeof dnr.isRegexSupported === "function") {
    const original = dnr.isRegexSupported.bind(dnr);
    put(dnr, "isRegexSupported", (options, callback) => {
      const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
        () => ({ isSupported: false, reason: "syntaxError" }));
      if (typeof callback !== "function") return p;
      p.then((r) => callback(r));
    });
  }
  if (dnr) for (const name of ["updateSessionRules", "updateDynamicRules"]) {
    if (typeof dnr[name] !== "function") continue;
    const original = dnr[name].bind(dnr);
    put(dnr, name, (options = {}, callback) => {
      if (options && Array.isArray(options.addRules)) options = { ...options, addRules: options.addRules.map(mendRule).filter(Boolean) };
      const attempt = async (opts, left) => {
        try { return await original(opts); }
        catch (e) {
          const at = /rule at index (\d+)/.exec(String(e && e.message));
          if (!at || !Array.isArray(opts.addRules) || left <= 0) throw e;
          const index = Number(at[1]);
          const rule = opts.addRules[index];
          try { native("debug.error", ["declarativeNetRequest: rule " + (rule && rule.id) + " left out — " + e.message]).catch(() => {}); } catch (x) {}
          return attempt({ ...opts, addRules: opts.addRules.filter((_, i) => i !== index) }, left - 1);
        }
      };
      const p = attempt(options, 100);
      if (typeof callback !== "function") return p;
      p.then(() => callback(), (e) => withLastError(e, callback));
    });
  }

  // Context menu entries for places Escale has no menu for — the old
  // toolbar button contexts are the button's menu now, and there is no
  // app launcher at all.
  for (const name of ["contextMenus", "menus"]) {
    const menus = chrome[name];
    if (!menus || typeof menus.create !== "function") continue;
    const mend = (props) => {
      if (!props || !Array.isArray(props.contexts)) return props;
      const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
      return { ...props, contexts: contexts.length ? contexts : ["page"] };
    };
    const create = menus.create.bind(menus), update = menus.update.bind(menus);
    put(menus, "create", (props, callback) => create(mend(props), callback));
    put(menus, "update", (id, props, callback) => update(id, mend(props), callback));
  }

  // webRequest listeners with options WebKit doesn't take — blocking
  // needs a policy-installed extension in Chrome's MV3 too; extra headers
  // WebKit reports anyway — are added with the options it does take.
  if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
    const target = chrome.webRequest[key];
    if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
    const add = target.addListener.bind(target);
    put(target, "addListener", (listener, filter, spec) => {
      // WebKit can't read ws:// and wss:// patterns, and refuses the
      // whole listener over one; Chrome watches sockets too. The
      // listener is kept for everything else.
      if (filter && Array.isArray(filter.urls)) {
        const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
        if (!urls.length) return;
        filter = { ...filter, urls };
      }
      // Added after a worker's startup, WebKit refuses it; Chrome takes
      // it. It isn't heard, but neither does it stop the code that added
      // it — a listener for every request can't join the late list
      // (it would wake the worker for all of them).
      const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
      try {
        if (!Array.isArray(spec)) return add(listener, filter);
        const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
        try { return add(listener, filter, kept); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return add(listener, filter); }
      } catch (e) { late(e); }
    });
  }

  // Tabs as Chrome describes them. Every tab has a groupId (-1 when in
  // no group — Escale has none), which code tests before anything else;
  // and with the "tabs" permission an extension sees every tab's address
  // and title, where WebKit shows them only for sites it has host
  // access to.
  if (chrome.tabs) {
    const seesTabs = (() => { try { return (runtime.getManifest().permissions || []).includes("tabs"); } catch (e) { return false; } })();
    const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
    // Mends in place; a promise only when the browser has to be asked.
    const mend = (list) => {
      const tabs = list.filter(isTab);
      for (const t of tabs) if (t.groupId === undefined) try { t.groupId = -1; } catch (e) {}
      let blind = seesTabs ? tabs.filter((t) => !t.url && t.index >= 0) : [];
      if (!blind.length) return null;
      return Promise.all(blind.map(inFront)).then((front) => {
        blind = blind.filter((t, i) => front[i]);
        return blind.length ? native("tabs.describe", [blind.map((t) => t.index)]) : [];
      }).then((info) => {
        blind.forEach((t, i) => {
          const d = info && info[i];
          if (!d) return;
          try { if (d.url) t.url = d.url; if (d.title && !t.title) t.title = d.title; } catch (e) {}
        });
      }, () => {});
    };
    const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
      : isTab(value) ? [value] : value && Array.isArray(value.tabs) ? value.tabs : [];
    const mendResult = (target, name) => {
      if (!target || typeof target[name] !== "function") return;
      const original = target[name].bind(target);
      put(target, name, (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const p = Promise.resolve(original(...args)).then(async (r) => { await mend(tabsIn(r)); return r; });
        if (!callback) return p;
        p.then((r) => callback(r), (e) => withLastError(e, callback));
      });
    };
    for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(chrome.tabs, name);
    for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
    // Listeners given a tab: the tab is mended before they see it.
    const mendArgs = (target, positions) => {
      if (!target || typeof target.addListener !== "function") return;
      const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
      const wrapped = new Map();
      put(target, "addListener", (listener, ...rest) => {
        const w = function (...args) {
          const pending = mend(positions.map((i) => args[i]));
          if (!pending) return listener.apply(this, args);
          pending.then(() => listener.apply(this, args));
        };
        wrapped.set(listener, w);
        return add(w, ...rest);
      });
      put(target, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
      put(target, "hasListener", (listener) => wrapped.has(listener));
    };
    mendArgs(chrome.tabs.onCreated, [0]);
    mendArgs(chrome.tabs.onUpdated, [2]);
    mendArgs(chrome.action && chrome.action.onClicked, [0]);
    mendArgs(chrome.contextMenus && chrome.contextMenus.onClicked, [1]);
    mendArgs(chrome.menus && chrome.menus.onClicked, [1]);
    mendArgs(chrome.commands && chrome.commands.onCommand, [1]);
  }
