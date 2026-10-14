// Answers the worker's tab messages, and relays the page's questions to the
// worker: the page sets nothing but a window message, the answer comes back
// on the shared DOM.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.kind === "tabPing") {
    setTimeout(() => sendResponse({ from: "content", href: location.href }), 100);
    return true;
  }
  // "frameCheck" is for the extension's page framed here.
});
window.addEventListener("message", (event) => {
  if (event.source !== window || !event.data || event.data.escaleAsk === undefined) return;
  chrome.runtime.sendMessage(event.data.escaleAsk).then(
    (reply) => { document.documentElement.dataset.reply = JSON.stringify({ reply: reply ?? null }); },
    (error) => { document.documentElement.dataset.reply = JSON.stringify({ error: String(error && error.message || error) }); });
});
document.documentElement.dataset.content = "ready";
