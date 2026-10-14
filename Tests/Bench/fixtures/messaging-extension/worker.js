// A first listener that never answers: Chrome waits for the one that does.
chrome.runtime.onMessage.addListener(() => undefined);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  switch (message && message.kind) {
    case "sync":
      sendResponse({ from: "worker", echo: message.echo });
      return;
    case "async":
      setTimeout(() => sendResponse({ from: "worker", late: true }), 300);
      return true;
    case "promise":
      return Promise.resolve({ from: "worker", promised: true });
    case "sender":
      sendResponse({ tab: sender.tab ? sender.tab.id : null, url: sender.url || null, frameId: sender.frameId ?? null });
      return;
    case "toTab":
      chrome.tabs.sendMessage(message.tabId, message.inner).then(
        (reply) => sendResponse({ reply: reply ?? null }),
        (error) => sendResponse({ error: String(error && error.message || error) }));
      return true;
    case "toTabCallback":
      chrome.tabs.sendMessage(message.tabId, message.inner, (reply) => {
        sendResponse({ reply: reply ?? null, lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
      });
      return true;
    case "ports":
      sendResponse(ports);
      return;
  }
  // "silent" and "page": not the worker's to answer.
});

const ports = [];
chrome.runtime.onConnect.addListener((port) => {
  let count = 0;
  ports.push("connected " + port.name);
  port.onMessage.addListener((message) => port.postMessage({ echo: message, n: ++count }));
  port.onDisconnect.addListener(() => ports.push("disconnected " + port.name));
});
