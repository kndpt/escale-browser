/*
Read only the main document already loaded by WebKit, in its isolated client
world. No fetch, mutation or installed observer. Bound text before crossing
into Swift; text/html is never a candidate, even when it contains JSON.
*/
(function () {
  const type = document.contentType.toLowerCase().split(';')[0];
  if (!(type === 'application/json' || type === 'text/json' || type.endsWith('+json') ||
        (location.protocol === 'file:' && location.pathname.toLowerCase().endsWith('.json') && type !== 'text/html')))
    throw new Error('This document is not served as JSON.');
  const root = document.body || document.documentElement;
  if (!root) throw new Error('The response is not available yet.');
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let text = '', node;
  while ((node = walker.nextNode())) {
    if (text.length + node.length > 2097152) throw new Error('JSON exceeds 2 MiB. Use the original response.');
    text += node.data;
  }
  return text;
})()
