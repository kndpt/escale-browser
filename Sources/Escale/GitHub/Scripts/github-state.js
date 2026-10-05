/*
Read once, in WebKit's isolated client world, the state labels a GitHub pull
request or issue page already shows. No fetch, mutation or installed observer.
GitHub draws the object's own state with Primer state labels (data-status) on
most views, and the older State--* class on Files changed. The older class
also marks other objects the conversation mentions: a closed pull request
listed eight merged ones that way. So Primer labels decide when there are any, and the older class only
when there are none. Within either, every label must agree, or the answer is
null: a page that shows another object's state is not evidence of its own.
Swift maps the token it returns.
*/
(function () {
  const agreed = found => (found.size === 1 ? [...found][0].slice(0, 40) : null);
  const primer = new Set();
  for (const label of document.querySelectorAll('[class*="StateLabel"][data-status]')) {
    primer.add(label.getAttribute('data-status'));
  }
  if (primer.size > 0) return agreed(primer);
  const older = new Set();
  for (const label of document.querySelectorAll('span.State[class*="State--"]')) {
    const named = [...label.classList].find(name => name.startsWith('State--') && name !== 'State--small');
    if (named) older.add(named);
  }
  return agreed(older);
})();
