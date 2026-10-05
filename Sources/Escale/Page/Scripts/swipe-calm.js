/*
Swipe navigation disables vertical overscroll in the page while the gesture is active.
A stylesheet keeps the adjustment separate from the page’s own inline styles.
*/
(function () {
  var sheet = document.createElement('style');
  sheet.id = 'escale-calm';
  sheet.textContent = 'html, body { overscroll-behavior-y: none; }';
  (document.head || document.documentElement).appendChild(sheet);
})();
