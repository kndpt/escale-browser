/*
A page stylesheet hides the selectors chosen for this site before first paint.
CSS arrives as JSON, preserving backticks, dollar signs, and line breaks.
*/
(function (options) {
  var sheet = document.getElementById('escale-veil');
  if (!sheet) {
    sheet = document.createElement('style');
    sheet.id = 'escale-veil';
    (document.head || document.documentElement).appendChild(sheet);
  }
  sheet.textContent = options.css;
})
