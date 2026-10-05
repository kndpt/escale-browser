/*
Middle-button scrolling runs inside the page to find the element under the pointer.
Stopping aborts its listeners and animation so disabling it leaves no page work.
*/
(() => {
  if (window.__escaleAutoScroll) return;
  // Every listener goes with this, when the setting is turned off.
  const quit = new AbortController();
  const held = { capture: true, signal: quit.signal };
  let active = null;
  // The button whose press just stopped the scrolling. Its click is part
  // of stopping, not a click of its own: landing on a link, it would
  // follow it, or open it in a new tab for the middle button.
  let swallow = -1;

  const scroller = (el) => {
    for (; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
      const s = getComputedStyle(el);
      if (/(auto|scroll|overlay)/.test(s.overflowY + s.overflowX) &&
          (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) return el;
    }
    return document.scrollingElement || document.documentElement;
  };

  // The mark: a round badge with its arrows, in a shadow root the page's
  // own styles can't reach.
  const mark = (x, y) => {
    const host = document.createElement('div');
    host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;pointer-events:none;' +
      `left:${x - 15}px;top:${y - 15}px;width:30px;height:30px;`;
    host.attachShadow({ mode: 'closed' }).innerHTML =
      '<svg viewBox="0 0 30 30" width="30" height="30" style="filter:drop-shadow(0 2px 6px rgba(0,0,0,.25))">' +
      '<circle cx="15" cy="15" r="13.5" fill="rgba(255,255,255,.94)" stroke="rgba(0,0,0,.18)"/>' +
      '<path d="M15 6.5l3.5 4.5h-7zM15 23.5l3.5-4.5h-7z" fill="rgba(0,0,0,.62)"/>' +
      '<circle cx="15" cy="15" r="1.6" fill="rgba(0,0,0,.62)"/></svg>';
    document.documentElement.appendChild(host);
    return host;
  };

  const speed = (d) => {
    const a = Math.abs(d) - 12;
    return a > 0 ? Math.sign(d) * Math.min(60, Math.pow(a / 10, 1.4)) : 0;
  };
  const tick = () => {
    if (!active) return;
    active.target.scrollBy(speed(active.dx), speed(active.dy));
    active.frame = requestAnimationFrame(tick);
  };
  const move = (e) => {
    if (!active) return;
    active.dx = e.clientX - active.x;
    active.dy = e.clientY - active.y;
  };
  const stop = () => {
    if (!active) return;
    cancelAnimationFrame(active.frame);
    active.badge.remove();
    document.documentElement.style.cursor = active.cursor;
    removeEventListener('mousemove', move, true);
    active = null;
  };

  addEventListener('mousedown', (e) => {
    swallow = -1;
    if (active) { e.preventDefault(); e.stopPropagation(); stop(); swallow = e.button; return; }
    if (e.button !== 1) return;
    if (e.target.closest && e.target.closest('a[href], area[href], input, textarea, select, button, video, audio, iframe, [contenteditable=""], [contenteditable="true"]')) return;
    e.preventDefault();
    active = {
      x: e.clientX, y: e.clientY, dx: 0, dy: 0, since: performance.now(),
      target: scroller(e.target), badge: mark(e.clientX, e.clientY),
      cursor: document.documentElement.style.cursor,
    };
    document.documentElement.style.cursor = 'all-scroll';
    addEventListener('mousemove', move, true);
    active.frame = requestAnimationFrame(tick);
  }, held);
  // Held down and dragged: let go, and it stops.
  addEventListener('mouseup', (e) => {
    if (active && e.button === 1 && performance.now() - active.since > 250 &&
        (Math.abs(active.dx) > 12 || Math.abs(active.dy) > 12)) { stop(); swallow = 1; }
  }, held);
  const eat = (e) => {
    if (e.button === swallow) { swallow = -1; e.preventDefault(); e.stopPropagation(); }
    else if (e.button === 1 && active) e.preventDefault();
  };
  addEventListener('click', eat, held);
  addEventListener('auxclick', eat, held);
  addEventListener('keydown', (e) => { if (active && e.key === 'Escape') { e.preventDefault(); stop(); } }, held);
  addEventListener('wheel', stop, { capture: true, passive: true, signal: quit.signal });
  addEventListener('blur', stop, { signal: quit.signal });
  document.addEventListener('visibilitychange', stop, { signal: quit.signal });

  window.__escaleAutoScroll = () => {
    stop();
    quit.abort();
    delete window.__escaleAutoScroll;
  };
})();
