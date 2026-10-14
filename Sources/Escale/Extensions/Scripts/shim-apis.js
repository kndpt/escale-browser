  // Part of the extension shim (ExtensionShims.parts): whole namespaces
  // WebKit lacks, answered by the browser or refused as Chrome refuses.

  // Whole namespaces WebKit lacks, answered by the browser.
  const define = (name, methods, events = [], extra = {}) => {
    if (chrome[name]) return;
    const api = Object.assign({}, extra);
    for (const m of methods) api[m] = call(name + "." + m);
    for (const e of events) api[e] = event();
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  define("bookmarks",
    ["get", "getChildren", "getRecent", "getSubTree", "getTree", "search", "create", "move", "update", "remove", "removeTree"],
    ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"]);
  define("history",
    ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
    ["onVisited", "onVisitRemoved"]);
  define("downloads",
    ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon"],
    ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]);
  define("sidePanel", ["open", "setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior"]);
  define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
    { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
  define("tabGroups", ["get", "query", "update", "move"],
    ["onCreated", "onRemoved", "onUpdated", "onMoved"], { TAB_GROUP_ID_NONE: -1 });
  define("fontSettings",
    ["getFontList", "getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize",
     "clearDefaultFontSize", "getDefaultFixedFontSize", "setDefaultFixedFontSize", "clearDefaultFixedFontSize",
     "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"],
    ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]);
  define("management", ["getSelf", "getAll", "get", "setEnabled", "uninstallSelf"],
    ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);
  define("notifications", ["create", "update", "clear", "getAll", "getPermissionLevel"],
    ["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"]);
  define("tts", ["speak", "stop", "pause", "resume", "isSpeaking", "getVoices"], ["onVoicesChanged"]);
  define("identity",
    ["launchWebAuthFlow", "getAuthToken", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens"],
    ["onSignInChanged"],
    { getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, "") });

  // Chrome's settings objects: get, set and clear, and an event.
  const setting = (name) => ({
    get: call("setting.get:" + name), set: call("setting.set:" + name),
    clear: call("setting.clear:" + name), onChange: event(),
  });
  const settings = (prefix, names) =>
    Object.fromEntries(names.map((n) => [n, setting(prefix + "." + n)]));
  const put2 = (name, api) => {
    if (chrome[name]) return;
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  // Something only Chrome can do, answered the way Chrome answers when
  // it can't: a rejection, or lastError for a callback.
  const refuse = (what) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const error = new Error(what + " isn't available in Escale");
    if (!callback) return Promise.reject(error);
    withLastError(error, callback);
  };

  define("search", ["query"]);
  define("idle", ["queryState", "getAutoLockDelay"], [],
    { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } });
  if (chrome.idle && !chrome.idle.onStateChanged) {
    // Asked every so often while anyone listens, the way Chrome
    // notices on its own.
    const changed = event(), add = changed.addListener;
    let every = 60, state = "active", timer = null;
    changed.addListener = (f) => {
      add(f);
      if (timer) return;
      timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
        if (now === state) return;
        state = now;
        for (const g of changed.listeners) try { g(now); } catch (e) { setTimeout(() => { throw e; }); }
      }).catch(() => {}), 15000);
    };
    put(chrome.idle, "onStateChanged", changed);
    put(chrome.idle, "setDetectionInterval", (seconds) => { every = Math.max(15, Number(seconds) || 60); });
  }
  define("power", ["requestKeepAwake", "releaseKeepAwake", "reportActivity"]);
  define("browsingData",
    ["remove", "removeAppcache", "removeCache", "removeCacheStorage", "removeCookies", "removeDownloads",
     "removeFileSystems", "removeFormData", "removeHistory", "removeIndexedDB", "removeLocalStorage",
     "removePasswords", "removeServiceWorkers", "removeWebSQL", "settings"]);
  define("sessions", ["getRecentlyClosed", "getDevices", "restore"], ["onChanged"], { MAX_SESSION_RESULTS: 25 });
  define("topSites", ["get"]);
  define("readingList", ["query", "addEntry", "removeEntry", "updateEntry"],
    ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"]);
  put2("system", {
    cpu: { getInfo: call("system.cpu.getInfo") },
    memory: { getInfo: call("system.memory.getInfo") },
    storage: { getInfo: call("system.storage.getInfo"), ejectDevice: refuse("system.storage.ejectDevice"),
               getAvailableCapacity: refuse("system.storage.getAvailableCapacity"), onAttached: event(), onDetached: event() },
    display: { getInfo: call("system.display.getInfo"), onDisplayChanged: event() },
  });
  put2("privacy", {
    services: settings("privacy.services", ["alternateErrorPagesEnabled", "autofillAddressEnabled",
      "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
      "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
    network: settings("privacy.network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
    websites: settings("privacy.websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled",
      "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
      "thirdPartyCookiesAllowed", "topicsEnabled"]),
    IPHandlingPolicy: { DEFAULT: "default", DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: "default_public_and_private_interfaces",
      DEFAULT_PUBLIC_INTERFACE_ONLY: "default_public_interface_only", DISABLE_NON_PROXIED_UDP: "disable_non_proxied_udp" },
  });
  const contentSetting = () => ({
    get: (details, cb) => { const v = { setting: "allow" }; if (cb) cb(v); else return Promise.resolve(v); },
    set: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
    clear: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
    getResourceIdentifiers: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
  });
  put2("contentSettings", Object.fromEntries(["automaticDownloads", "autoVerify", "camera", "clipboard", "cookies",
    "images", "javascript", "location", "microphone", "notifications", "plugins", "popups", "sound"]
    .map((n) => [n, contentSetting()])));
  put2("proxy", { settings: setting("proxy.settings"), onProxyError: event() });
  put2("omnibox", { setDefaultSuggestion: () => {}, onInputStarted: event(), onInputChanged: event(),
    onInputEntered: event(), onInputCancelled: event(), onDeleteSuggestion: event() });
  put2("tabCapture", { capture: refuse("tabCapture.capture"), getMediaStreamId: refuse("tabCapture.getMediaStreamId"),
    getCapturedTabs: (cb) => { if (cb) cb([]); else return Promise.resolve([]); }, onStatusChanged: event() });
  // The picker Chrome would show, cancelled: an empty stream id.
  put2("desktopCapture", { chooseDesktopMedia: (sources, tab, cb) => { const f = typeof tab === "function" ? tab : cb; if (f) setTimeout(() => f("", {})); return 1; },
    cancelChooseDesktopMedia: () => {}, DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" } });
  put2("pageCapture", { saveAsMHTML: refuse("pageCapture.saveAsMHTML") });
  put2("debugger", { attach: refuse("debugger.attach"), detach: refuse("debugger.detach"),
    sendCommand: refuse("debugger.sendCommand"), getTargets: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
    onEvent: event(), onDetach: event() });
  put2("gcm", { register: refuse("gcm.register"), unregister: refuse("gcm.unregister"), send: refuse("gcm.send"),
    onMessage: event(), onMessagesDeleted: event(), onSendError: event() });
  put2("instanceID", { getID: refuse("instanceID.getID"), getToken: refuse("instanceID.getToken"),
    deleteID: refuse("instanceID.deleteID"), deleteToken: refuse("instanceID.deleteToken"),
    getCreationTime: refuse("instanceID.getCreationTime"), onTokenRefresh: event() });
  // Rules that show a button on matching pages: every button is always
  // shown in Escale, so there is nothing for them to do.
  const rules = () => ({ addRules: (r, cb) => { if (cb) cb(r || []); }, removeRules: (i, cb) => { if (cb) cb(); },
    getRules: (i, cb) => { const f = typeof i === "function" ? i : cb; if (f) f([]); } });
  put2("declarativeContent", { onPageChanged: rules(),
    PageStateMatcher: function (o) { Object.assign(this, o); }, ShowAction: function () {}, ShowPageAction: function () {},
    SetIcon: function (o) { Object.assign(this, o); }, RequestContentScript: function (o) { Object.assign(this, o); } });
