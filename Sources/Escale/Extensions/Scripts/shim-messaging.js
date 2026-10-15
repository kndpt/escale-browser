  // Part of the extension shim (ExtensionShims.parts): Chrome's messaging
  // between the worker, the extension's pages and its frames in websites.

  // Several onMessage listeners: WebKit takes the first one's return —
  // usually undefined — as the answer, where Chrome waits for whichever
  // calls sendResponse or returns true. So the extension's listeners are
  // gathered behind a single one of WebKit's that follows Chrome's rule.
  const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
  // The extension's background, whichever WebKit runs: the worker, or a
  // page — it picks the page when a manifest names scripts as well.
  const background = worker || (!inContent && typeof document !== "undefined" && (() => {
    try { return chrome.extension && typeof chrome.extension.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
    catch (e) { return false; }
  })());
  // The tab an extension's framed page is in, asked once (see __escaleToFrame).
  let ownTab = null;
  // Who has something to say about a message, told between the
  // extension's worker and its own pages on a channel they share (one
  // origin): each says, as soon as its listeners have run, whether it
  // answers or lets the message pass, and the sender says so of what
  // it sends. A page with nothing to say can then stay silent only
  // as long as someone else may still answer (see the end of `dispatch`).
  // A page in a website's frame is on the website's side of the
  // channel and takes no part; it waits, as before.
  const channel = !inContent && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("escale-messages") : null;
  const me = Math.random().toString(36).slice(2);
  const peers = new Set();
  const verdicts = new Map();
  const waiting = new Set();
  const present = new Set();
  // Pages that are there but didn't hear the last message sent to all —
  // WebKit doesn't bring every message to every page. Not waited for
  // until they say something about one they heard.
  const deaf = new Set();
  const keyOf = (message) => { try { const k = JSON.stringify(message); return k && k.length < 4000 ? k : null; } catch (e) { return null; } };
  const tell = (message, verdict, heard) => {
    const key = channel && keyOf(message);
    if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
  };
  if (channel) {
    channel.onmessage = ({ data }) => {
      if (!data || data.from === me) return;
      // The pages that listen, as they come and go.
      if (!background && data.hello) {
        const known = peers.has(data.from);
        peers.add(data.from);
        if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
        return;
      }
      if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
      // A popup that closes is thrown away without a word; so a page
      // left waiting asks who is still there.
      if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
      if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
      if (typeof data.key !== "string") return;
      const now = Date.now();
      for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
      const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
      verdicts.delete(data.key);
      verdicts.set(data.key, entry);
      entry.at = now;
      if (data.from === "worker") entry.worker = data;
      else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
      waiting.forEach((check) => check());
    };
    if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
  }
  // Only a page that listens for messages is waited for: one that
  // doesn't never hears them, so never says anything about them.
  let listening = false;
  const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
  const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
  const gather = (event, told) => {
    if (!event || typeof event.addListener !== "function") return;
    const add = event.addListener.bind(event);
    const remove = event.removeListener.bind(event);
    const listeners = new Set();
    let attached = false;
    const dispatch = function (message, sender, respond) {
      let settled = false, keep = false;
      const sendResponse = (value) => { if (!settled) { settled = true; respond(value); } };
      // Only the worker answers; any other page stays out of it.
      if (message && message.__escalePing === true) {
        if (background) { sendResponse("pong"); return; }
        return true;
      }
      if (message && message.__escaleUserScript === true) {
        const route = root.__escaleUserScriptMessage;
        return route && route(message.message, sender, sendResponse) && !settled ? true : undefined;
      }
      // A tab's message, handed on by the worker (see alsoFramed): taken
      // by the frame it names, in the tab it names; every other page lets
      // it pass without answering, as it would a message not for it.
      if (message && message.__escaleToFrame) {
        const to = message.__escaleToFrame;
        if (!embedded || !(to.urls || []).includes(location.href)) {
          if (!background) setTimeout(() => sendResponse(undefined), 10000);
          return background ? undefined : true;
        }
        if (!ownTab) ownTab = Promise.resolve(runtime.sendMessage({ __escaleCall: { space: "tabs", method: "getCurrent", args: [] } }))
          .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
        ownTab.then((id) => {
          if (id !== to.tabId) return setTimeout(() => sendResponse(undefined), 10000);
          let kept = false;
          for (const listener of [...listeners]) {
            let result;
            try { result = listener(to.message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) kept = true;
            else if (result && typeof result.then === "function") { kept = true; result.then(sendResponse, () => sendResponse(undefined)); }
          }
          if (!kept) sendResponse(undefined);
        });
        return true;
      }
      // A call one of the extension's pages in a website's frame can't
      // make itself (see `embedded`), made here for it — and only for
      // one of its pages: a content script gets no more than Chrome
      // gives it.
      if (message && message.__escaleCall) {
        if (!background) return true;
        const { space, method, args } = message.__escaleCall;
        const own = (() => { try { return new URL(sender.url).origin === location.origin; } catch (e) { return false; } })();
        if (!own) { sendResponse({ error: "chrome." + space + " isn't available to content scripts" }); return; }
        if (space === "tabs" && method === "getCurrent") { sendResponse({ value: sender.tab }); return; }
        let ns; try { ns = chrome[space]; } catch (e) {}
        if (!ns || typeof ns[method] !== "function") { sendResponse({ error: "chrome." + space + "." + method + " isn't available" }); return; }
        Promise.resolve().then(() => ns[method](...(args || [])))
          .then((value) => sendResponse({ value }), (e) => sendResponse({ error: String(e && e.message || e) }));
        return true;
      }
      for (const listener of [...listeners]) {
        let result;
        try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
        if (result === true) keep = true;
        else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
      }
      if (!inContent) tell(message, keep || settled ? "answers" : "passes", true);
      if (keep || settled) return keep && !settled ? true : undefined;
      // Nothing here answers it. In Chrome that leaves the question to
      // the extension's other pages and its worker; WebKit takes the
      // first reply from any of them, and an empty one from a page that
      // only listens for something else — an offscreen document, an
      // options page — would arrive before the worker's real answer. So
      // a page that has nothing to say steps aside, and says nothing
      // only once everyone else has had ample time — or as soon as the
      // worker and every other open page have said they let it pass too,
      // or the worker sent it itself. Bitwarden's offscreen document
      // keeps its storage and answers a save with nothing: ten seconds
      // on each one got in the way of signing in.
      if (!background && !inContent) {
        const received = Date.now();
        const key = channel && keyOf(message);
        let check = () => {}, roll = null;
        const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
        const late = setTimeout(() => { done(); sendResponse(undefined); }, 10000);
        if (key) {
          // Only what was said about this message, not an identical one
          // a while ago.
          const fresh = (said) => said && said.at >= received - 2000;
          check = () => {
            const entry = verdicts.get(key);
            if (settled || !entry) return;
            const worker = entry.worker;
            if (fresh(worker) && worker.verdict === "answers") { done(); return; }
            const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
            if (said.some((p) => fresh(p) && p.verdict === "answers")) { done(); return; }
            if (!fresh(worker) || said.some((p) => !fresh(p))) return;
            done();
            sendResponse(undefined);
          };
          waiting.add(check);
          check();
          // Still waiting on someone after a moment: those who don't say
          // they are here within a second are gone, and those who do but
          // still have said nothing about this message didn't hear it.
          roll = setTimeout(() => {
            if (settled) return;
            const heard = new Set();
            const hear = (id) => heard.add(id);
            present.add(hear);
            channel.postMessage({ roll: true, from: me });
            setTimeout(() => {
              present.delete(hear);
              for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
              const entry = verdicts.get(key);
              for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
              check();
            }, 1000);
          }, 200);
        }
        return true;
      }
      return undefined;
    };
    put(event, "addListener", (listener) => {
      listeners.add(listener);
      if (told) join();
      if (!attached) { attached = true; add(dispatch); }
    });
    put(event, "removeListener", (listener) => {
      listeners.delete(listener);
      if (told && listeners.size === 0) leave();
      if (attached && listeners.size === 0) { attached = false; remove(dispatch); }
    });
    put(event, "hasListener", (listener) => listeners.has(listener));
    put(event, "hasListeners", () => listeners.size > 0);
    // A worker may only add listeners while it starts; one that adds its
    // first later would be refused. So in a worker the one listener is
    // WebKit's from the start.
    if (background) { attached = true; add(dispatch); }
  };

  // In a website's frame, everything WebKit keeps to the extension's own
  // process goes through the worker instead. What stays direct is what
  // WebKit lets a content script call too. Namespaces the shim adds
  // itself further down answer through the browser, which is allowed.
  if (embedded) {
    const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
    const ask = (space, method, args) => {
      while (args.length && args[args.length - 1] === undefined) args.pop();
      let payload;
      try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
      return Promise.resolve(chrome.runtime.sendMessage({ __escaleCall: { space, method, args: payload } })).then((reply) => {
        if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
        if (reply.error) throw new Error(reply.error);
        return reply.value;
      });
    };
    for (const space of spaces) {
      if (direct.has(space)) continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const name of names) {
        if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
        let f; try { f = ns[name]; } catch (e) { continue; }
        if (typeof f !== "function") continue;
        // A port can't be carried over: one that closes at once, as
        // Chrome's does when nothing answers, rather than a dead process.
        if (name === "connect") {
          put(ns, name, (...args) => {
            const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
              postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
            setTimeout(() => withLastError("Could not establish connection. Receiving end does not exist.", () => {
              for (const f of [...port.onDisconnect.listeners]) f(port);
            }));
            return port;
          });
          continue;
        }
        put(ns, name, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = ask(space, name, args);
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
    }
  }

  // WebKit unloads an extension's worker after half a minute idle, and
  // starts it again for an event only if it remembers a listener for
  // it — which it does for messages, the worker's listener being in
  // place from its first line (see gather).
  //
  // A reply that never came is answered Chrome's way: in callback
  // form, with lastError set — WebKit calls back with nothing and no
  // error, and code that pings a tab to see if its script is there
  // waits for ever.
  const replied = (promise, callback, gone) => {
    if (typeof callback !== "function") return promise;
    promise.then((r) => r === undefined ? withLastError(new Error(gone), callback) : callback(r),
      (e) => withLastError(e, callback));
  };
  let checkWorker = () => {};
  // When the worker was last heard from — a reply, a port message.
  let heard = 0;
  if (runtime && typeof runtime.sendMessage === "function") {
    const page = typeof document !== "undefined";
    // WebKit's own, looked up at each call — not held from the page's
    // first moment, when the page isn't yet the tab or popup it will be.
    const original = Object.getPrototypeOf(runtime).sendMessage;
    const send = (...args) => original.apply(chrome.runtime === proxy ? runtime : chrome.runtime, args);
    // WebKit can also lose a worker without knowing — its process
    // stopped along with a tab's — and then answers every message with
    // nothing, for good. So after waking it, a page asks the worker
    // itself (its shim answers) at most every few seconds; no answer,
    // and the browser takes the extension up afresh.
    const hasWorker = (() => { try { const b = runtime.getManifest().background || {}; return !!(b.service_worker || b.scripts || b.page); } catch (e) { return false; } })();
    // The message itself doesn't wait on the answer: a worker busy
    // starting up can take seconds. An empty reply means gone; silence
    // for a quarter of a minute does too.
    let asking = false;
    const check = () => {
      if (!hasWorker || asking || Date.now() - heard < 5000) return;
      asking = true;
      // Asked three times, a second apart, then once more after waking
      // it — only then taken for gone: a restart has consequences
      // (welcome pages, a popup loading again), and a question can go
      // unanswered for reasons that pass. Waking a worker that runs
      // starts it over, so that is kept for last.
      const ping = Object.getPrototypeOf(runtime).sendMessage;
      const ask = () => Promise.race([ping.call(runtime, { __escalePing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
      const pause = (ms) => new Promise((w) => setTimeout(w, ms));
      const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
        () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
      const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
      const started = Date.now();
      attempt(0).then((r) => {
        // Any real answer from the worker meanwhile says it runs, too:
        // the question alone can go unheard from a page that listens.
        if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
        else {
          if (__ESCALE_VERBOSE__) native("debug.error", ["worker check: " + String(r) + " from " + location.pathname]).catch(() => {});
          native("background.revive", []).catch(() => {});
        }
      }).finally(() => { asking = false; });
    };
    checkWorker = page ? check : () => {};
    put(runtime, "sendMessage", (...args) => {
      const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
      // Never heard back by the one that sends it, so said for it.
      if (!inContent) tell(typeof args[0] === "string" && args.length > 1 && typeof args[1] !== "function" ? args[1] : args[0], "passes");
      checkWorker();
      const answer = send(...args).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
      return replied(answer, callback, "The message port closed before a response was received.");
    });
  }
  // A message for a tab reaches only its content scripts in WebKit. In
  // Chrome it reaches the extension's own pages framed in that tab too —
  // 1Password's sign-in banner is one, told this way to offer a passkey
  // instead of a password, and without it the site's request failed. So
  // the worker hands it to those frames as well, and the first answer
  // from either wins.
  const alsoFramed = (answer, tabId, message, options) => {
    const nav = chrome.webNavigation;
    if (!nav || typeof nav.getAllFrames !== "function" || typeof tabId !== "number") return answer;
    const own = runtime.getURL("");
    const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
    const framed = Promise.resolve(nav.getAllFrames({ tabId })).then((frames) => {
      const urls = (frames || []).filter((f) => f.url && f.url.startsWith(own) && f.frameId !== 0 && (wanted === null || f.frameId === wanted)).map((f) => f.url);
      if (!urls.length) return undefined;
      return Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __escaleToFrame: { tabId, urls, message } });
    }, () => undefined);
    return new Promise((resolve, reject) => {
      let left = 2, failure = null;
      const none = () => { if (--left === 0) failure ? reject(failure) : resolve(undefined); };
      answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failure = e; none(); });
      framed.then((v) => v !== undefined ? resolve(v) : none(), () => none());
    });
  };
  if (chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
    const send = chrome.tabs.sendMessage.bind(chrome.tabs);
    put(chrome.tabs, "sendMessage", (tabId, message, options, callback) => {
      if (typeof options === "function") { callback = options; options = undefined; }
      const p = options === undefined ? send(tabId, message) : send(tabId, message, options);
      return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
    });
  }
  if (typeof document !== "undefined" && runtime && typeof runtime.connect === "function") {
    const connect = runtime.connect.bind(runtime);
    put(runtime, "connect", (...args) => {
      checkWorker();
      const port = connect(...args);
      try { port.onMessage.addListener(() => { heard = Date.now(); }); } catch (e) {}
      return port;
    });
  }

  gather(runtime && runtime.onMessage, true);
  gather(runtime && runtime.onMessageExternal);
