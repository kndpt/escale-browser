// WebKit uses contentHint when choosing video adaptation. A screen containing
// text benefits from detail over motion; cameras and audio keep their defaults.
// Only annotate the native capture result, preserving permissions, constraints,
// errors and track ownership. The site can still select motion after capture.
(() => {
  const prototype = globalThis.MediaDevices?.prototype;
  const descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, 'getDisplayMedia');
  if (typeof descriptor?.value !== 'function' || !descriptor.configurable) return;
  const capture = descriptor.value;
  const wrapped = function getDisplayMedia(...args) {
    // Call synchronously while the original user gesture is still active.
    return Reflect.apply(capture, this, args).then(stream => {
      for (const track of stream.getVideoTracks()) {
        try {
          if (track.contentHint === '') track.contentHint = 'detail';
        } catch (_) { /* An unsupported hint must not turn an allowed capture into a failure. */ }
      }
      return stream;
    });
  };
  Object.defineProperty(prototype, 'getDisplayMedia', {...descriptor, value: wrapped});
})();
