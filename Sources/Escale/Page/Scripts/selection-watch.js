/*
The page reports a text selection made with the mouse to Escale's selection menu.
Reactivation reuses one set of listeners so toggling the feature cannot accumulate observers.
*/
(() => {
    if (window.__escaleSelection) { window.__escaleSelection.on = true; return; }
    const state = { on: true };
    window.__escaleSelection = state;
    let shown = false;

    function post(body) {
        webkit.messageHandlers.selection.postMessage(body);
    }

    function hide() {
        if (!shown) return;
        shown = false;
        post({});
    }

    // Text being written is the writer's: no menu over a field or an editor.
    function editable(node) {
        const el = node && (node.nodeType === 1 ? node : node.parentElement);
        if (!el) return false;
        return el.isContentEditable || !!el.closest('input, textarea, select');
    }

    // Where the menu goes: the selected line nearest the pointer, and the
    // selection's own top and bottom so the menu never lands on it.
    function spot(x, y) {
        const selection = getSelection();
        if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
        if (!selection.toString().trim()) return null;
        const active = document.activeElement;
        if (active && (active.localName === 'input' || active.localName === 'textarea' || active.isContentEditable)) return null;
        const range = selection.getRangeAt(0);
        if (editable(range.commonAncestorContainer)) return null;
        const rects = Array.from(range.getClientRects()).filter(r => r.width > 1 && r.height > 1);
        if (!rects.length) return null;
        let top = Infinity, bottom = -Infinity, best = rects[0], score = Infinity;
        for (const r of rects) {
            top = Math.min(top, r.top);
            bottom = Math.max(bottom, r.bottom);
            const dy = y < r.top ? r.top - y : y > r.bottom ? y - r.bottom : 0;
            const dx = x < r.left ? r.left - x : x > r.right ? x - r.right : 0;
            // A line above or below counts more than a gap beside the text.
            if (dy * 4 + dx < score) { score = dy * 4 + dx; best = r; }
        }
        let lineTop = Infinity, lineBottom = -Infinity, left = Infinity, right = -Infinity;
        for (const r of rects) {
            if (Math.abs(r.top - best.top) >= 4) continue;
            lineTop = Math.min(lineTop, r.top);
            lineBottom = Math.max(lineBottom, r.bottom);
            left = Math.min(left, r.left);
            right = Math.max(right, r.right);
        }
        // The viewport's width gives the page's scale, zoom and magnification together.
        return { x: Math.min(right, Math.max(left, x)), lineTop, lineBottom, top, bottom, viewport: innerWidth };
    }

    addEventListener('mouseup', event => {
        if (!state.on || event.button !== 0) return;
        const x = event.clientX, y = event.clientY;
        // After the page's own mouseup handlers, which may change the selection.
        // Not a frame callback: WebKit holds those while the window is hidden.
        setTimeout(() => {
            const found = spot(x, y);
            if (!found) { hide(); return; }
            shown = true;
            post(found);
        }, 0);
    }, { capture: true, passive: true });

    addEventListener('mousedown', hide, { capture: true, passive: true });
    addEventListener('keydown', hide, { capture: true, passive: true });
    // Captured, so a scroll inside any element closes the menu too.
    addEventListener('scroll', hide, { capture: true, passive: true });
    addEventListener('resize', hide, { passive: true });
    // A pinch magnifies the page under the menu without resizing the window.
    if (window.visualViewport) visualViewport.addEventListener('resize', hide, { passive: true });
    addEventListener('pagehide', hide);
    document.addEventListener('selectionchange', () => {
        if (!shown) return;
        const selection = getSelection();
        if (!selection || selection.isCollapsed) hide();
    });
})();
