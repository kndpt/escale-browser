/*
The page stands still at its top and bottom edges instead of bouncing.
A stylesheet keeps the adjustment separate from the page’s own inline styles.
*/
(function () {
  var sheet = document.createElement('style');
  sheet.id = 'escale-calm';
  sheet.textContent = 'html, body { overscroll-behavior-y: none; }';
  (document.head || document.documentElement).appendChild(sheet);
})();
