(function (args) {
/*
Main-frame targeting in the isolated client world, installed only on request.
One pending animation frame coalesces pointer/focus/scroll events. Hit testing
visits at most eight open shadow roots, never scans the DOM. While targeting,
a short summary is posted only when the target changes, and its rectangle when
it moves. A click pins the element: the cover and input listeners go, the
outline and one scroll/resize listener stay until stop, so the pinned card
keeps pointing at it. Everything is removed on Escape, stop or navigation.
*/

  if (args.action === 'stop') {
    if (globalThis.__escaleVisualPick?.token === args.token) globalThis.__escaleVisualPick.stop();
    if (globalThis.__escaleVisualSelection?.token === args.token) delete globalThis.__escaleVisualSelection;
    return;
  }
  globalThis.__escaleVisualPick?.stop();
  delete globalThis.__escaleVisualSelection;
  let frame = 0, point = null, target = null, shown = null, pinned = null, ended = false, last = '';
  const cover = document.createElement('div');
  Object.assign(cover.style, {position:'fixed', inset:'0', zIndex:'2147483647', pointerEvents:'auto', cursor:'crosshair'});
  const outline = document.createElement('div');
  outline.setAttribute('data-escale-visual-pick', '');
  Object.assign(outline.style, {position:'fixed', pointerEvents:'none', zIndex:'2147483647', display:'none',
    boxSizing:'border-box', border:args.border + 'px solid ' + args.colour, background:args.wash});
  document.documentElement.append(cover, outline);
  const listeners = [];
  function listen(type, fn) { window.addEventListener(type, fn, true); listeners.push([type, fn]); }
  function release() {
    for (const [type, fn] of listeners) window.removeEventListener(type, fn, true);
    listeners.length = 0;
  }
  function stop() {
    if (ended) return;
    ended = true;
    if (frame) cancelAnimationFrame(frame);
    release();
    cover.remove(); outline.remove();
    if (globalThis.__escaleVisualPick?.token === args.token) delete globalThis.__escaleVisualPick;
  }
  function post(value) { window.webkit.messageHandlers.escaleVisualPick.postMessage({token:args.token, ...value}); }
  function element(x, y) {
    // The temporary pointer exclusion lets hit-testing see through the cover.
    // Its click interception also selects cross-origin iframes as host boxes.
    cover.style.pointerEvents = "none";
    let found = document.elementFromPoint(x, y);
    for (let depth = 0; found?.shadowRoot && depth < 8; depth++) {
      const inside = found.shadowRoot.elementFromPoint(x, y);
      if (!inside || inside === found) break;
      found = inside;
    }
    cover.style.pointerEvents = "auto";
    return found;
  }
  const clip = (value, limit = 512) => String(value).slice(0, limit);
  function box(r) { return {x:r.x, y:r.y, width:r.width, height:r.height}; }
  function viewport() { return {width:innerWidth, height:innerHeight}; }
  function label(found) {
    const name = found.tagName.toLowerCase();
    if (found.id) return clip(name + '#' + found.id, 64);
    const kind = typeof found.className === 'string' ? found.className.trim().split(/\s+/)[0] : '';
    return clip(kind ? name + '.' + kind : name, 64);
  }
  // Rounded to two decimals, so 57.99984px reads as 58px.
  function px(value) {
    const n = parseFloat(value);
    return /px$/.test(value) && isFinite(n) ? (Math.round(n * 100) / 100) + 'px' : clip(value, 32);
  }
  // A computed colour is rgb()/rgba() in sRGB; anything else (display-p3,
  // oklch) is shown as written, without a swatch.
  function paint(value) {
    const m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/.exec(value);
    if (!m) return {text:clip(value, 64)};
    const rgb = [m[1], m[2], m[3]].map(Number);
    let a = m[4] === undefined ? 1 : m[4].endsWith('%') ? parseFloat(m[4]) / 100 : Number(m[4]);
    const hex = '#' + rgb.map(c => Math.round(c).toString(16).padStart(2, '0')).join('').toUpperCase();
    return {text:a < 1 ? hex + ' · ' + Math.round(a * 100) + '%' : hex, rgba:[...rgb.map(c => c / 255), a]};
  }
  function padding(style) {
    const [t, r, b, l] = ['top','right','bottom','left'].map(side => px(style.getPropertyValue('padding-' + side)));
    if ([t, r, b, l].every(v => parseFloat(v) === 0)) return null;
    if (t === b && r === l) return t === r ? t : t + ' ' + r;
    return [t, r, b, l].join(' ');
  }
  function glance(found, style) {
    const r = found.getBoundingClientRect();
    const background = paint(style.backgroundColor);
    return {label:label(found), width:r.width, height:r.height,
      family:clip(style.fontFamily.split(',')[0].trim().replace(/^["']|["']$/g, ''), 64),
      size:px(style.fontSize), line:px(style.lineHeight), weight:clip(style.fontWeight, 8),
      colour:paint(style.color), background:background.rgba?.[3] === 0 ? null : background,
      padding:padding(style)};
  }
  function place(found) {
    const r = found.getBoundingClientRect();
    Object.assign(outline.style, {display:'block', left:r.left+'px', top:r.top+'px', width:r.width+'px', height:r.height+'px'});
    return r;
  }
  function draw() {
    frame = 0;
    if (ended) return;
    if (pinned) {
      const found = pinned.deref();
      if (!found?.isConnected) { stop(); post({kind:'cancelled'}); return; }
      const r = place(found), key = [r.x, r.y, r.width, r.height].join();
      if (key !== last) { last = key; post({kind:'moved', rect:box(r), viewport:viewport()}); }
      return;
    }
    if (point) target = element(point.x, point.y);
    if (!target || target === outline || target === cover) return;
    const r = place(target), key = [r.x, r.y, r.width, r.height].join();
    if (target !== shown) {
      shown = target; last = key;
      post({kind:'hover', glance:glance(target, getComputedStyle(target)), rect:box(r), viewport:viewport()});
    } else if (key !== last) {
      last = key;
      post({kind:'moved', rect:box(r), viewport:viewport()});
    }
  }
  function schedule() { if (!frame) frame = requestAnimationFrame(draw); }
  function choose(found) {
    if (!found || found === outline || found === cover || ended) return;
    const r = found.getBoundingClientRect(), style = getComputedStyle(found);
    const properties = ['font-family','font-size','font-weight','line-height','letter-spacing',
      'color','background-color','background-image','margin','padding','gap','border-width','box-sizing','transform'];
    const styles = properties.map(name => ({name, value:clip(style.getPropertyValue(name))}));
    styles.unshift({name:'Inline font family', value:clip(found.style.fontFamily || '(none)')});
    const result = {kind:'selected', label:clip(found.tagName.toLowerCase() + (found.id ? '#'+found.id : '')),
      rect:box(r), scroll:{x:scrollX,y:scrollY}, viewport:viewport(), styles, glance:glance(found, style),
      frame:found.tagName === 'IFRAME', shadow:found.getRootNode() instanceof ShadowRoot};
    // Pinned: the page gets its input back; only the outline follows scroll.
    release();
    cover.remove();
    pinned = new WeakRef(found);
    last = [r.x, r.y, r.width, r.height].join();
    place(found);
    listen('scroll', schedule);
    listen('resize', schedule);
    globalThis.__escaleVisualSelection = {token:args.token, element:new WeakRef(found)};
    post(result);
  }
  function block(event) { event.preventDefault(); event.stopImmediatePropagation(); }
  listen('pointermove', event => { point={x:event.clientX,y:event.clientY}; schedule(); });
  listen('focusin', event => { point=null; target=event.composedPath()[0]; schedule(); });
  listen('scroll', schedule);
  listen('resize', schedule);
  for (const type of ['pointerdown','pointerup','mousedown','mouseup','auxclick','dblclick','contextmenu']) listen(type, block);
  listen('click', event => { block(event); choose(element(event.clientX,event.clientY)); });
  listen('keydown', event => {
    if (event.key === 'Escape') { block(event); stop(); post({kind:'cancelled'}); }
    else if (event.key === 'Enter') { block(event); choose(target || document.activeElement); }
  });
  target = document.activeElement === document.body ? null : document.activeElement;
  if (target) schedule();
  globalThis.__escaleVisualPick = {token:args.token, stop};
})
