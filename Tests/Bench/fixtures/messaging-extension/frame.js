// An extension page in a website's frame (Vimium's bar, a password
// manager's list): it hears the worker's tab messages, and its privileged
// calls must not cost the website's process.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.kind === "frameCheck") sendResponse({ from: "frame" });
});
chrome.tabs.query({}).then(
  (tabs) => parent.postMessage({ escaleFrame: { tabs: tabs.length } }, "*"),
  (error) => parent.postMessage({ escaleFrame: { error: String(error && error.message || error) } }, "*"));
