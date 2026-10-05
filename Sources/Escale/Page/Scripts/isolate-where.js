/*
Floating-video controls read playback position from the page video.
Unknown duration returns a safe default rather than a misleading fraction.
*/
(function () {
  var video = document.querySelector('[data-escale-float]')
    || document.querySelector('video');
  if (!video || !video.duration || !isFinite(video.duration)) return [0, true];
  return [video.currentTime / video.duration, !video.paused];
})();
