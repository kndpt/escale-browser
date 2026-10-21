/*
The page names its selected text for a text fragment: the passage, or its first and last words when long or across blocks, plus words around it while it recurs.
Run once per click in the main frame; null where no fragment would find the text again (a field, a frame, text missing from the page's text, a passage no nearby words tell apart).
*/
(() => {
    const selection = getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
    const active = document.activeElement;
    if (active && (/^(INPUT|TEXTAREA|SELECT|IFRAME|FRAME|OBJECT|EMBED)$/.test(active.tagName) || active.isContentEditable)) return null;
    const range = selection.getRangeAt(0);
    if (range.startContainer.getRootNode() !== document || range.endContainer.getRootNode() !== document) return null;

    const norm = s => s.replace(/\s+/g, ' ').trim();
    const words = s => norm(s).split(' ').filter(Boolean);
    // A fragment's terms match within one block, so context comes from the
    // blocks the passage starts and ends in.
    const block = node => {
        let el = node.nodeType === 1 ? node : node.parentElement;
        while (el && el !== document.body && /^(inline|contents)/.test(getComputedStyle(el).display)) el = el.parentElement;
        return el || document.body;
    };
    const head = document.createRange();
    head.selectNodeContents(block(range.startContainer));
    head.setEnd(range.startContainer, range.startOffset);
    const tail = document.createRange();
    tail.selectNodeContents(block(range.endContainer));
    tail.setStart(range.endContainer, range.endOffset);
    let before = head.toString(), after = tail.toString(), text = selection.toString();

    // Terms match whole words: a word cut by the selection is taken whole.
    const letter = /^[\p{L}\p{N}]/u, lead = before.match(/[\p{L}\p{N}]+$/u), trail = after.match(/^[\p{L}\p{N}]+/u);
    if (lead && letter.test(text)) { text = lead[0] + text; before = before.slice(0, -lead[0].length); }
    if (trail && /[\p{L}\p{N}]$/u.test(text)) { text += trail[0]; after = after.slice(trail[0].length); }

    const lines = text.split(/[\n\r\t]+/).map(norm).filter(Boolean);
    if (!lines.length) return null;
    const page = norm(document.body.innerText).toLowerCase();
    // 0, 1 or 2: more than once is all that matters.
    const count = s => {
        s = s.toLowerCase();
        const at = page.indexOf(s);
        return at < 0 ? 0 : page.indexOf(s, at + 1) < 0 ? 1 : 2;
    };

    const whole = lines.join(' ');
    const exact = lines.length === 1 && whole.length <= 300;
    let start = whole, end = '';
    if (!exact) {
        // A few words each side, more while the first ones recur or the last
        // ones come up earlier in the passage than its end.
        const first = words(lines[0]), last = words(lines[lines.length - 1]), lower = whole.toLowerCase();
        let n = Math.min(3, first.length), m = Math.min(3, last.length);
        start = first.slice(0, n).join(' ');
        while (count(start) > 1 && n < Math.min(10, first.length)) start = first.slice(0, ++n).join(' ');
        end = last.slice(-m).join(' ');
        const late = () => lower.indexOf(end.toLowerCase(), start.length) === lower.length - end.length;
        while (!late() && m < Math.min(10, last.length)) end = last.slice(-++m).join(' ');
    }
    if (!count(start)) return null;

    const ahead = words(before), behind = words(after);
    const gapBefore = /\s$/.test(before) || /^\s/.test(text) ? ' ' : '';
    const gapAfter = /^\s/.test(after) || /\s$/.test(text) ? ' ' : '';
    let prefix = '', suffix = '';
    const seen = () => (prefix ? prefix + gapBefore : '') + start + (suffix ? gapAfter + suffix : '');
    for (let n = 1; n <= 5 && count(seen()) > 1; n++) {
        const p = ahead.slice(-n).join(' '), s = exact ? behind.slice(0, n).join(' ') : '';
        if (p === prefix && s === suffix) break;
        prefix = p;
        suffix = s;
    }
    // Still found twice, the link would highlight the first one instead.
    if (count(seen()) > 1) return null;
    return { start, end, prefix, suffix };
})()
