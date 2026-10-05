  const chrome = (() => {
    const runtime = globalThis.chrome.runtime;
    return { runtime: {
      id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
      sendMessage: (message, ...rest) => runtime.sendMessage({ __escaleUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
      connect: (info) => runtime.connect({ ...(info || {}), name: "escale-us:" + ((info && info.name) || "") }),
    } };
  })();
  const browser = chrome;
