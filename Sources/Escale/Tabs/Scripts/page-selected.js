/*
The page returns selected text for native commands, including same-origin frames.
Cross-origin frames are ignored because their documents cannot be read safely.
*/
(function read(doc) {
  var el = doc.activeElement;
  if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
    try { return el.contentDocument ? read(el.contentDocument) : ''; } catch (e) { return ''; }
  }
  if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
    try {
      var from = el.selectionStart, to = el.selectionEnd;
      if (typeof from === 'number' && typeof to === 'number' && to > from) return el.value.slice(from, to);
    } catch (e) {}
  }
  if (el && el.tagName === 'INPUT' && el.type === 'password') return '';
  var s = doc.getSelection();
  return s ? s.toString() : '';
})(document)
