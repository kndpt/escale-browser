(function (args) {
/*
Read one document or selected element rectangle on demand (any other mode,
the visible page and a drawn area, only needs the viewport). Never scroll,
resize the page, click, submit, load lazy content or wait for infinite scroll.
A selected element is a weak reference left by explicit visual targeting.
*/

  if (location.href !== args.url) throw new Error('The page changed. Capture again.');
  let rect = {x:0,y:0,width:innerWidth,height:innerHeight};
  if (args.mode === 'full') {
    rect.width = Math.max(innerWidth,document.documentElement.scrollWidth,document.body?.scrollWidth || 0);
    rect.height = Math.max(innerHeight,document.documentElement.scrollHeight,document.body?.scrollHeight || 0);
  } else if (args.mode === 'element') {
    const selected = globalThis.__escaleVisualSelection;
    const element = selected?.token === args.token ? selected.element.deref() : null;
    if (!element?.isConnected) throw new Error('The selected element is gone. Pick it again.');
    const r = element.getBoundingClientRect();
    rect = {x:r.x+scrollX,y:r.y+scrollY,width:r.width,height:r.height};
  }
  return {rect,viewport:{width:innerWidth,height:innerHeight},scroll:{x:scrollX,y:scrollY}};
})
