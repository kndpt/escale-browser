/*
Reader mode finds the page section with substantial prose and few links.
The heuristic discounts navigation rails without needing a site-specific rule.
Its colours, width and scale are variables Escale sets on the root (its
"dress", from Palette): set again alone, they restyle the article in place.
*/
(function (asked) {
  var root = document.documentElement.style;
  for (var name in asked.dress) root.setProperty('--escale-' + name, asked.dress[name]);
  if (!asked.build) return 'dressed';

  function prose(el) {
    var paragraphs = el.querySelectorAll('p');
    if (paragraphs.length < 2) return 0;
    var letters = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      letters += (paragraphs[i].innerText || '').length;
    }
    if (letters < 400) return 0;
    // A rail of related links has plenty of text and nothing to read.
    var links = el.querySelectorAll('a').length;
    return letters / (1 + links * 14);
  }

  function best() {
    var candidates = document.querySelectorAll(
      'article, main, [role="main"], .post, .entry, .article, .content, #content, div, section'
    );
    var top = null, mark = 0;
    for (var i = 0; i < candidates.length; i++) {
      var score = prose(candidates[i]);
      if (score > mark) { mark = score; top = candidates[i]; }
    }
    return top;
  }

  var article = best();
  if (!article) return 'none';

  // Every picture is resolved while the real page is still standing.
  //
  // currentSrc is what the browser actually chose and loaded, after srcset,
  // sizes and <picture> have had their say. Reading it here and writing it
  // back as a plain src is the only way to be sure the reader shows the
  // same image the page did — copying the markup alone gets you a lazy
  // placeholder, or nothing at all.
  var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
              'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
  var pictures = article.querySelectorAll('img');
  for (var i = 0; i < pictures.length; i++) {
    var picture = pictures[i];
    picture.setAttribute('loading', 'eager');
    var real = picture.currentSrc || picture.getAttribute('src') || '';
    // A one-pixel placeholder counts as nothing.
    if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
      for (var k = 0; k < late.length; k++) {
        var kept = picture.getAttribute(late[k]);
        if (kept) { real = kept; break; }
      }
    }
    if (real) picture.setAttribute('src', real);
    var lateSet = picture.getAttribute('data-srcset');
    if (lateSet && !picture.getAttribute('srcset')) {
      picture.setAttribute('srcset', lateSet);
    }
  }

  var heading = document.querySelector('h1');
  var title = (heading && heading.innerText.trim()) || document.title;

  var sheet = document.createElement('style');
  sheet.textContent = [
    'html,body{background:var(--escale-ground) !important;margin:0 !important;padding:0 !important}',
    '#escale-reader{max-width:var(--escale-width);margin:0 auto;padding:72px 24px 160px;',
    'font:400 calc(18px * var(--escale-scale))/1.72 ui-serif,Georgia,"Times New Roman",serif;',
    'color:var(--escale-ink)}',
    // The site's own colours were chosen for its ground, not this one,
    // inline ones too: hence !important, here and on each role below.
    '#escale-reader *{color:inherit !important;background-color:transparent !important}',
    '#escale-reader h1{font:600 calc(30px * var(--escale-scale))/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
    'margin:0 0 8px;letter-spacing:-0.01em}',
    '#escale-reader .escale-from{font:400 calc(12px * var(--escale-scale))/1 -apple-system,sans-serif;',
    'color:var(--escale-caption) !important;margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
    '#escale-reader p{margin:0 0 1.35em}',
    '#escale-reader img,#escale-reader video,#escale-reader iframe{max-width:100%;',
    'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
    '#escale-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
    '#escale-reader figure{margin:1.8em 0}',
    '#escale-reader figcaption{font:400 calc(13px * var(--escale-scale))/1.5 -apple-system,sans-serif;',
    'color:var(--escale-caption) !important;margin-top:.6em}',
    '#escale-reader a{color:var(--escale-ink) !important;text-underline-offset:3px}',
    '#escale-reader h2,#escale-reader h3{font:600 calc(20px * var(--escale-scale))/1.3 -apple-system,sans-serif;',
    'margin:2em 0 .6em}',
    '#escale-reader pre,#escale-reader code{font-family:ui-monospace,monospace;',
    'font-size:calc(14px * var(--escale-scale))}',
    '#escale-reader pre{background:var(--escale-code) !important;padding:14px;border-radius:8px;overflow:auto}',
    '#escale-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
    'border-left:2px solid var(--escale-rule);color:var(--escale-quote) !important}'
  ].join('');

  var wrap = document.createElement('div');
  wrap.id = 'escale-reader';
  // Copied as nodes, never as a string of HTML: a page that requires Trusted
  // Types refuses the string, even an empty one, and reading did nothing.
  for (var node = article.firstChild; node; node = node.nextSibling) {
    wrap.appendChild(node.cloneNode(true));
  }

  // What was arranged around the words rather than being part of them.
  // Not header: an article's opening image lives there as often as not.
  var clutter = wrap.querySelectorAll(
    'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
    '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
  );
  for (var c = 0; c < clutter.length; c++) clutter[c].remove();

  // Embedded video is part of the article; every other frame is not.
  var players = /youtube|youtu\.be|vimeo|dailymotion|loom\.com|streamable|wistia|ted\.com/i;
  var frames = wrap.querySelectorAll('iframe');
  for (var f = 0; f < frames.length; f++) {
    var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
    if (players.test(where)) {
      frames[f].setAttribute('src', where);
      frames[f].removeAttribute('height');
      frames[f].removeAttribute('width');
    } else {
      frames[f].remove();
    }
  }

  // A picture with nothing behind it is a broken icon, which is worse than
  // no picture at all.
  var kept = wrap.querySelectorAll('img');
  for (var g = 0; g < kept.length; g++) {
    var src = kept[g].getAttribute('src') || '';
    if (!src || src.indexOf('data:image') === 0) kept[g].remove();
  }

  var top = document.createElement('h1');
  top.textContent = title;
  var from = document.createElement('p');
  from.className = 'escale-from';
  from.textContent = location.host.replace(/^www\./, '');

  document.body.replaceChildren();
  document.head.appendChild(sheet);
  wrap.insertBefore(from, wrap.firstChild);
  wrap.insertBefore(top, wrap.firstChild);
  document.body.appendChild(wrap);
  window.scrollTo(0, 0);
  return 'read';
})
