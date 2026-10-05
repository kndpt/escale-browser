/*
Form observation protects drafts and connects sign-in fields to Escale's password UI.
Its two changing switches arrive as JSON, so Swift never quotes JavaScript by hand.
*/
(function (options) {
  if (window.__escaleForms) return;
  var saving = options.saving === true, filling = options.filling === true;

  // The password box, and the last box before it that could hold a name.
  function pair() {
    var boxes = document.querySelectorAll('input[type="password"]');
    var pass = null;
    for (var p = 0; p < boxes.length; p++) {
      var b = boxes[p];
      var r = b.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) { pass = b; break; }
    }
    if (!pass) return null;
    var scope = pass.form || (pass.closest && pass.closest('form')) || document;
    var all = scope.querySelectorAll('input');
    var user = null;
    for (var i = 0; i < all.length; i++) {
      if (all[i] === pass) break;
      var kind = (all[i].type || 'text').toLowerCase();
      if (kind === 'text' || kind === 'email' || kind === 'tel') user = all[i];
    }
    return { user: user, pass: pass };
  }

  function put(box, value) {
    if (!box) return;
    var setter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value'
    );
    if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
    box.dispatchEvent(new Event('input', { bubbles: true }));
    box.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // What was typed by hand and not yet sent, box by box. A page whose
  // boxes still hold it is not put to sleep: waking it couldn't bring
  // that back. A box emptied by sending — a chat's composer — no longer
  // counts, and neither does a search box.
  var typed = [];
  document.addEventListener('input', function (e) {
    if (!e.isTrusted) return;
    var el = e.target;
    if (!el || typed.indexOf(el) >= 0) return;
    typed.push(el);
    if (typed.length > 40) typed.shift();
  }, true);
  function unsaved() {
    for (var i = 0; i < typed.length; i++) {
      var el = typed[i];
      if (!el.isConnected) continue;
      var tag = (el.tagName || '').toLowerCase();
      if (tag === 'textarea') {
        if (el.value.trim() && el.value !== el.defaultValue) return true;
      } else if (tag === 'input') {
        var kind = (el.type || 'text').toLowerCase();
        if (['text', 'email', 'url', 'tel', 'number'].indexOf(kind) < 0) continue;
        if (el.value.trim() && el.value !== el.defaultValue) return true;
      } else if (el.isContentEditable) {
        if ((el.textContent || '').trim()) return true;
      }
    }
    return false;
  }

  window.__escaleForms = {
    unsaved: unsaved,
    fill: function (user, password) {
      var both = pair();
      if (!both) return false;
      if (both.user && !both.user.value) put(both.user, user);
      put(both.pass, password);
      return true;
    },
    // Whether there is still a sign-in on the page. Asked after a
    // password went out, to tell a sign-in that took from one refused —
    // and one still there is watched, in case it goes without a new page.
    hasPassword: function () {
      var there = !!pair();
      if (there && saving) watch();
      return there;
    },
    signIns: function (save, fill) {
      saving = save;
      filling = fill;
      if (!saving) unwatch();
      if (!filling) hanging = false;
    }
  };

  // What is in the boxes when they are sent. Said every time — a click
  // on "show password" says it too — because the browser only listens
  // once the page has moved on, and keeps the last thing it heard.
  function offer() {
    if (!saving) return;
    var both = pair();
    if (!both || !both.pass.value) return;
    window.webkit.messageHandlers.escaleForms.postMessage({
      kind: 'submit',
      user: both.user ? both.user.value : '',
      password: both.pass.value
    });
    watch();
  }

  document.addEventListener('submit', offer, true);
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter' || !saving) return;
    var both = pair();
    if (both && (document.activeElement === both.pass || document.activeElement === both.user)) offer();
  }, true);
  // Plenty of sign-in buttons aren't in a form and never fire submit.
  document.addEventListener('click', function (e) {
    var el = e.target;
    if (!saving || !el || !el.closest) return;
    if (el.closest('button, input[type="submit"], [role="button"]')) {
      setTimeout(offer, 0);
    }
  }, true);

  // The boxes going away without a new page — a sign-in done in place —
  // is the other way a sign-in shows it took. Watched for only once a
  // password has gone out, and for as long as the browser holds on to it
  // (45 s, see Tab.settleSignIn); every page watched for good was
  // searched for sign-in boxes at each change of its DOM, which for a
  // feed or a chat is many times a second. Each look waits 100 ms for
  // the changes behind it, however many there are.
  var watching = null, looking = null, settling = null, ending = null;
  function unwatch() {
    if (watching) watching.disconnect();
    clearTimeout(looking);
    clearTimeout(settling);
    clearTimeout(ending);
    watching = looking = settling = ending = null;
  }
  function look() {
    looking = null;
    if (pair()) {
      clearTimeout(settling);
      settling = null;
      return;
    }
    if (settling) return;
    settling = setTimeout(function () {
      settling = null;
      if (pair()) return;
      unwatch();
      window.webkit.messageHandlers.escaleForms.postMessage({ kind: 'settled' });
    }, 400);
  }
  function watch() {
    clearTimeout(ending);
    ending = setTimeout(unwatch, 45000);
    if (watching) return;
    watching = new MutationObserver(function () {
      if (!looking) looking = setTimeout(look, 100);
    });
    watching.observe(document.documentElement, { childList: true, subtree: true });
  }

  // Whether the caret is somewhere on the page that takes typing.
  //
  // The browser gives Tab to its own row of tabs, which is right until you
  // are filling something in: plenty of fields offer a completion you take
  // with Tab, and stealing the key there would make them unusable.
  function editable(el) {
    if (!el) return false;
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'textarea') return true;
    if (el.isContentEditable === true) return true;
    if (el.getAttribute && el.getAttribute('role') === 'textbox') return true;
    // A document that types into a frame of its own — Google Docs keeps
    // the caret there. ⌘⇧V is that document's paste, so the frame counts.
    if (tag === 'iframe') {
      try { return editable(el.contentDocument && el.contentDocument.activeElement); }
      catch (e) { return false; }
    }
    if (tag !== 'input') return false;
    var kind = (el.type || 'text').toLowerCase();
    return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
            'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
  }

  // Whether something hangs from the sign-in box the caret is in.
  var hanging = false;
  function caret() {
    var el = document.activeElement;
    var rect = null;
    // Only an input can be one of the pair: anywhere else, the page
    // isn't searched for them.
    if (filling && el && (el.tagName || '').toLowerCase() === 'input') {
      var both = pair();
      if (both && (el === both.user || el === both.pass)) {
        var r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
      }
    }
    hanging = !!rect;
    window.webkit.messageHandlers.escaleForms.postMessage({
      kind: 'focus',
      typing: editable(el),
      rect: rect
    });
  }

  // The box moves when the page scrolls or the window changes size, and
  // whatever hangs from it has to move too. Once a frame at most, and
  // only while something does: every frame of every scroll was a
  // message to the browser and a search of the page, for nothing.
  var moving = false;
  function moved() {
    if (moving || !hanging) return;
    moving = true;
    requestAnimationFrame(function () { moving = false; caret(); });
  }
  window.addEventListener('scroll', moved, true);
  window.addEventListener('resize', moved);

  // Going full screen, announced before it happens rather than after.
  //
  // WebKit puts the video in a window of its own and slides ours away
  // behind it. For a frame or two ours is still on screen, and everything
  // this browser draws is white — which is the pale band across the top of
  // the animation. Knowing a moment early is enough to paint it black.
  function immersed() {
    var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
    window.webkit.messageHandlers.escaleForms.postMessage({
      kind: 'fullscreen', on: on
    });
  }
  document.addEventListener('fullscreenchange', immersed, true);
  document.addEventListener('webkitfullscreenchange', immersed, true);

  // The asking, caught before the animation starts.
  ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']
    .forEach(function (name) {
      var was = Element.prototype[name];
      if (!was) return;
      Element.prototype[name] = function () {
        window.webkit.messageHandlers.escaleForms.postMessage({
          kind: 'fullscreen', on: true
        });
        return was.apply(this, arguments);
      };
    });

  document.addEventListener('focusin', caret, true);
  document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
  document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
  caret();
})
