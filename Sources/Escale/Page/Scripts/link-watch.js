/*
The page names the link under each right-click, or none, for Escale's own menu entries.
It runs in Escale's script world, in every frame, so a page can neither read nor post to it, and only a real press counts.
*/
(() => {
  addEventListener('contextmenu', event => {
    // A page can dispatch its own contextmenu on a link of its choosing; only a real press names one.
    if (!event.isTrusted) return;
    let link = {};
    // The composed path reaches links inside open shadow trees, where `target` stops at the host.
    for (const node of event.composedPath()) {
      if (node.nodeType !== 1 || (node.localName !== 'a' && node.localName !== 'area')) continue;
      // An SVG link's href is an object, and its address may be relative.
      const href = typeof node.href === 'string' ? node.href : node.href && node.href.baseVal;
      if (!href) continue;
      try {
        const address = new URL(href, node.baseURI).href;
        if (!address.startsWith('javascript:')) {
          link = { href: address, text: String(node.innerText ?? node.textContent ?? '').slice(0, 1000) };
        }
      } catch {}
      break;
    }
    webkit.messageHandlers.escaleLinkMenu.postMessage(link);
  }, { passive: true, capture: true });
})();
