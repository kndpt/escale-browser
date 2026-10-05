/*
The reading bar receives bounded scroll reports through its named message handler.
The handler name arrives as JSON so it cannot change the script source.
*/
(function (options) {
  if (window.__escaleScroll) return;
  var waiting = false;
  function tell() {
    var root = document.documentElement;
    var y = window.scrollY || root.scrollTop || 0;
    var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
    window.webkit.messageHandlers[options.handler].postMessage({ y: y, max: ceiling });
  }
  function scrolled() {
    if (waiting) return;
    waiting = true;
    requestAnimationFrame(function () { waiting = false; tell(); });
  }
  window.addEventListener('scroll', scrolled, { passive: true });
  window.__escaleScroll = function () {
    window.removeEventListener('scroll', scrolled);
    delete window.__escaleScroll;
  };
  tell();
})
