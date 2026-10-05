/*
Floating video can exist in both the page and a WebKit picture-in-picture window.
Stopping both prevents an orphaned second copy.
*/
(function () {
  // The engine may have put the video in its own floating window as well —
  // some players ask for that themselves. Leaving one and not the other
  // leaves you with two.
  try {
    var out = document.querySelector('video[data-escale-float]')
      || document.querySelector('video');
    if (out) {
      if (out.webkitPresentationMode === 'picture-in-picture') {
        out.webkitSetPresentationMode('inline');
      }
      if (document.pictureInPictureElement && document.exitPictureInPicture) {
        document.exitPictureInPicture();
      }
    }
  } catch (e) {}

  clearInterval(window.__escaleFloatWatch);
  window.__escaleFloatWatch = null;
  document.documentElement.classList.remove('escale-floating');
  var sheet = document.getElementById('escale-float');
  if (sheet) sheet.textContent = '';
  var video = document.querySelector('[data-escale-float]');
  if (video) video.removeAttribute('data-escale-float');
  return 'landed';
})();
