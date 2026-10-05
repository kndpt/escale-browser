/*
Middle-click handling observes trusted page events to open links in Escale tabs.
The one-time guard prevents duplicate handling when the page script is installed again.
*/
(function () {
  if (window.__escaleMiddle) return;
  window.__escaleMiddle = true;
  document.addEventListener('auxclick', function (e) {
    if (e.button !== 1 || !e.isTrusted || e.defaultPrevented) return;
    // The path, not the parents: a link inside an open shadow root is
    // on it too. An <area> of an image map is a link, and so is an SVG
    // <a>, whose href is an object that holds the address as written.
    var path = e.composedPath();
    for (var i = 0; i < path.length; i++) {
      var el = path[i];
      var tag = el.tagName ? el.tagName.toLowerCase() : '';
      if (tag !== 'a' && tag !== 'area') continue;
      var href = el.href;
      if (href && typeof href === 'object') {
        try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
      }
      if (!href) continue;
      window.webkit.messageHandlers.escaleMiddle.postMessage({ href: href });
      return;
    }
  });
})();
