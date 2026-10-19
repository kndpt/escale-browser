(function (args) {
/*
Screens (Screens.swift) asks this on demand only: when the tool opens, after
a load and once a new width has settled. It reads the widths at which the
page's own CSS changes, from every stylesheet the page lets it read, and the
elements that stick out past the viewport's sides: the overflow that makes a
phone scroll sideways. An edge is the first width of a layout, so
`min-width: 768px` and `max-width: 767.98px` are both 768. Nothing stays
behind but, while asked, an outline on those elements and the one style
element that draws it.

WebKit can send a page's resize before it lays the page out at a new fixed
size, and none after: a page whose script listens for resize would stay at
the old size. So the last size a resize carried is kept, and one more is
sent when the page has a size it was never told.
*/

  const mark = 'data-escale-overflow';
  const styleID = 'escale-screens-overflow';
  for (const element of document.querySelectorAll('[' + mark + ']')) element.removeAttribute(mark);
  document.getElementById(styleID)?.remove();
  if (args.action === 'clear') return null;

  const told = globalThis.__escaleScreensTold ||= (() => {
    const last = {size: ''};
    addEventListener('resize', () => { last.size = innerWidth + 'x' + innerHeight; });
    return last;
  })();
  if (told.size !== innerWidth + 'x' + innerHeight) dispatchEvent(new Event('resize'));

  // Media queries measure em and rem against the initial font size, not the
  // page's.
  const px = (value, unit) => Number(value) * (unit === 'px' ? 1 : 16);
  const from = value => Math.ceil(value - 0.001);
  const after = value => Math.floor(value + 0.001) + 1;
  const edges = new Set();
  const length = '([\\d.]+)(px|r?em)';
  const rules = [
    [new RegExp('\\(\\s*min-width\\s*:\\s*' + length, 'g'), m => from(px(m[1], m[2]))],
    [new RegExp('\\(\\s*max-width\\s*:\\s*' + length, 'g'), m => after(px(m[1], m[2]))],
    [new RegExp('(?<![-\\w])width\\s*(>=|>|<=|<)\\s*' + length, 'g'),
      m => (m[1] === '>=' || m[1] === '<' ? from : after)(px(m[2], m[3]))],
    [new RegExp(length + '\\s*(>=|>|<=|<)\\s*width(?![-\\w])', 'g'),
      m => (m[3] === '<=' || m[3] === '>' ? from : after)(px(m[1], m[2]))],
  ];
  const read = text => {
    if (!text) return;
    for (const [pattern, edge] of rules)
      for (const m of text.matchAll(pattern)) {
        const value = edge(m);
        if (value > 0 && value < 8000 && edges.size < 64) edges.add(value);
      }
  };
  let unread = 0;
  const seen = new Set();
  const sheet = s => {
    if (!s || seen.has(s)) return;
    seen.add(s);
    read(s.media?.mediaText);
    let list;
    // A stylesheet from another origin keeps its rules to itself.
    try { list = s.cssRules; } catch { unread++; return; }
    walk(list);
  };
  const walk = list => {
    for (const rule of list || []) {
      if (rule.styleSheet) { sheet(rule.styleSheet); continue; }
      if (rule.media) read(rule.media.mediaText);
      if (rule.cssRules) walk(rule.cssRules);
    }
  };
  for (const s of document.styleSheets) sheet(s);
  for (const s of document.adoptedStyleSheets || []) sheet(s);

  // Only a page that does scroll sideways has overflow to show, and then the
  // outermost element past an edge is the one to fix: what it holds sticks
  // out because it does.
  const width = document.documentElement.clientWidth;
  const scroller = document.scrollingElement || document.documentElement;
  const found = [];
  if (scroller.scrollWidth > width + 1 && document.body) {
    const clipped = element => {
      for (let up = element.parentElement; up && up !== document.body; up = up.parentElement)
        if (getComputedStyle(up).overflowX !== 'visible') return true;
      return false;
    };
    const all = document.body.getElementsByTagName('*');
    const outside = new Set();
    for (let i = 0; i < all.length && i < 20000; i++) {
      const r = all[i].getBoundingClientRect();
      if (!r.width || !r.height) continue;
      if (r.right + scrollX > width + 0.5 || r.left + scrollX < -0.5) outside.add(all[i]);
    }
    for (const element of outside) {
      if (outside.has(element.parentElement)) continue;
      if (getComputedStyle(element).position === 'fixed' || clipped(element)) continue;
      found.push(element);
    }
  }
  if (args.show && found.length) {
    for (const element of found.slice(0, 50)) element.setAttribute(mark, '');
    const style = document.createElement('style');
    style.id = styleID;
    style.textContent = '[' + mark + ']{outline:2px dashed ' + args.colour + ' !important;outline-offset:-2px !important}';
    (document.head || document.documentElement).appendChild(style);
    if (args.reveal) found[0].scrollIntoView({block: 'center', inline: 'nearest'});
  }
  return {edges: [...edges].sort((a, b) => a - b), unread, overflow: found.length,
          width: innerWidth, height: innerHeight};
})
