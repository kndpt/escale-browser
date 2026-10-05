/*
Floating video seeks relative to its current position without altering the page.
The requested offset arrives as JSON.
*/
(function (options) {
  var video = document.querySelector('[data-escale-float]')
    || document.querySelector('video');
  if (!video) return false;
  video.currentTime = Math.max(0, video.currentTime + (options.seconds));
  return true;
})
