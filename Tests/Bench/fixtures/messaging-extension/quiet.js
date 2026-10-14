// An extension page that listens, like an offscreen document or an options
// page: its silence must not stand in for the worker's answer.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.kind === "page") sendResponse({ from: "quiet page" });
});
