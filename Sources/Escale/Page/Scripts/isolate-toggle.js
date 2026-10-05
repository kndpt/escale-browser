/*
Floating-video controls act on the isolated video, or the first page video.
The page performs playback changes to keep control with the media element.
*/
(function () {
  var video = document.querySelector('[data-escale-float]')
    || document.querySelector('video');
  if (!video) return true;
  if (video.paused) { video.play(); } else { video.pause(); }
  return !video.paused;
})();
