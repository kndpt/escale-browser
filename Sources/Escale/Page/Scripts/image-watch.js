/*
The page remembers the image under a context-menu click for the native menu.
The single listener avoids adding another observer on repeated injection.
*/
(function () {
  if (window.__escaleImages) return;
  window.__escaleImages = true;
  document.addEventListener('contextmenu', function (e) {
    var el = e.target;
    while (el && el.tagName !== 'IMG') el = el.parentElement;
    if (!el || !el.currentSrc || el.naturalWidth < 2) return;
    // Only an address this menu will act on takes WebKit's own menu
    // away; any other scheme keeps it, rather than getting nothing.
    if (!/^(https?|data|blob):/i.test(el.currentSrc)) return;
    e.preventDefault();
    window.webkit.messageHandlers.escaleImages.postMessage({ src: el.currentSrc });
  }, true);
})();
