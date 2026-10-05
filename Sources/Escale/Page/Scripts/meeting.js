/*
A meeting in the floating window is drawn by the page itself, from what the page
already has: the people in it, as the call site names and shows them, and the
screen someone shares. Nothing is received twice. Each card plays the stream the
site's own tile plays, so no connection or decoder is added, a photo is drawn
from the image the tile has already loaded, never fetched again, and the site's
pictures go on existing underneath, out of sight, where its own code keeps
choosing which streams to receive.

The composition is Escale's, not the site's: the site lays out what fits the
window it thinks it is in, which in a small window is one picture. So the window
keeps the site in a large viewport (see Meeting.swift) and draws its own compact
one over it: the people along the top, the shared screen below at its own shape,
never cut. Without a shared screen the people fill the window.

How a call site names things is read in one place below, `hints`: tiles carry
`data-participant-id`, buttons their accessible names. These come from Meet's
markup as remembered, not from a qualified page (see docs/MEDIA.md, "Reading a
Meet page"). A site that has none of them still shows whoever arrived over the
network.

The window asks for the page's state twice a second and presses the page's own
buttons: the page owns the meeting. A button that cannot be found is reported
as absent, and the window offers no control it could not press.
*/
(function (options) {
  var root = document.documentElement;
  var HOST = 'escale-meeting';

  var hints = {
    tiles: '[data-participant-id]',
    ownName: '[data-self-name]',
    microphone: { name: 'button[jsname="BOHaEe"]', label: /micro|mikro|マイク/i, among: 'button[data-is-muted]' },
    camera: { label: /camera|caméra|kamera|cámara|câmera|カメラ/i, among: 'button[data-is-muted]' },
    present: { label: /^(present|stop presenting|you are presenting|share screen|stop sharing|pr[ée]sent|vous pr[ée]sentez|arr[êe]ter la pr[ée]sentation|partager l['’][ée]cran|präsent|presentar|dejar de presentar)/i, among: 'button[aria-label]' },
    hand: { label: /(raise|lower) hand|(lever|baisser) la main|hand (heben|senken)|(levantar|bajar) la mano/i, among: 'button[aria-label]' },
    leave: { name: 'button[jsname="CQylAd"]', label: /^(leave call|quitter l['’]appel|anruf verlassen|verlassen|salir de la llamada)/i, among: 'button[aria-label]' },
    // A toggle that is on often says so by offering to undo it.
    stopping: /^(stop|lower|arr[êe]ter|baisser|beenden|senken|dejar|bajar|you are presenting|vous pr[ée]sentez)/i,
    // "Vous êtes en train de présenter", "Ada (Presentation)": accents count.
    presentation: /pr[eé]sent|präsent|presentaci|apresenta/i,
    silent: /^mic_off$|^mic_none$/,
    silentLabel: /micro\w* (is )?(off|muted|coupé|désactivé|aus)|is muted|est coupé|stummgeschaltet/i,
    icon: /symbol|icon|material/i
  };

  // A button the page draws now. One kept in the markup but not shown is not
  // a button anyone could press.
  function shown(element) { return !!element && element.getClientRects().length > 0; }

  // By the name a person hears first: markup names change between versions
  // of a site, what a button is called for a screen reader much less.
  function button(hint) {
    var all = document.querySelectorAll(hint.among);
    for (var i = 0; i < all.length; i++) {
      if (hint.label.test(all[i].getAttribute('aria-label') || '') && shown(all[i])) return all[i];
    }
    var named = hint.name && document.querySelector(hint.name);
    return shown(named) ? named : null;
  }

  function pressed(element) {
    return element.getAttribute('aria-pressed') === 'true'
      || hints.stopping.test(element.getAttribute('aria-label') || '');
  }

  function tracks(stream, kind) {
    if (!stream || !stream.getTracks) return [];
    return stream.getTracks().filter(function (t) { return t.kind === kind && t.readyState === 'live'; });
  }

  // WebKit names what came from a peer connection "remote video" (or audio).
  // Anything the page drew or captured itself carries the name of its source.
  function remote(stream, kind) {
    return tracks(stream, kind).some(function (t) { return t.label === 'remote ' + kind; });
  }

  // The meeting is on while the page offers a way to leave it, or while
  // anything still arrives from the other side.
  function live() {
    if (button(hints.leave)) return true;
    var media = document.querySelectorAll('video, audio');
    for (var i = 0; i < media.length; i++) {
      if (remote(media[i].srcObject, 'audio') || remote(media[i].srcObject, 'video')) return true;
    }
    return false;
  }

  function state() {
    var mic = button(hints.microphone), camera = button(hints.camera);
    var present = button(hints.present), hand = button(hints.hand);
    return {
      live: live(),
      mic: mic ? (mic.getAttribute('data-is-muted') === 'true' ? 'muted' : 'open') : null,
      camera: camera ? (camera.getAttribute('data-is-muted') === 'true' ? 'off' : 'on') : null,
      present: present ? (pressed(present) ? 'on' : 'off') : null,
      hand: hand ? (pressed(hand) ? 'up' : 'down') : null,
      leave: !!button(hints.leave),
      asking: !!asked()
    };
  }

  if (options.action === 'state') return state();

  // Leaving as its host, Meet asks whether to leave or to end the call for
  // everyone, in a dialog nobody sees while the page floats. The window's
  // button says leave, so it answers leave, and never ends the call for others.
  function asked() {
    var dialogs = document.querySelectorAll('[role="dialog"], [role="alertdialog"]');
    for (var i = 0; i < dialogs.length; i++) {
      var choices = dialogs[i].querySelectorAll('button, [role="button"]');
      for (var j = 0; j < choices.length; j++) {
        var words = (choices[j].getAttribute('aria-label') || choices[j].textContent || '').trim();
        if (hints.leave.label.test(words) && shown(choices[j])) return choices[j];
      }
    }
    return null;
  }

  if (options.action === 'press') {
    var pressable = ['microphone', 'camera', 'present', 'hand', 'leave'];
    var target = options.name === 'leave' && asked()
      || pressable.indexOf(options.name) >= 0 && button(hints[options.name]);
    if (!target) return false;
    target.click();
    return true;
  }
  if (options.action === 'off') {
    clearInterval(window.__escaleMeetingWatch);
    window.__escaleMeetingWatch = null;
    window.__escaleMeeting = null;
    root.classList.remove('escale-meeting');
    var host = document.querySelector(HOST);
    if (host) {
      // The streams are the site's; a card lets go of them as it goes.
      host.shadowRoot.querySelectorAll('video').forEach(function (v) { v.srcObject = null; });
      host.remove();
    }
    var sheet = document.getElementById('escale-meeting-page');
    if (sheet) sheet.remove();
    return 'landed';
  }

  // action 'on': nothing to float before the meeting has begun.
  if (!live()) return 'none';

  // MARK: - who is in it

  // The first words in a tile that are not a button, a menu or an icon's
  // ligature ("mic_off" is a word to a font, not a name).
  function nameOf(tile) {
    var own = tile.querySelector(hints.ownName);
    if (own && own.textContent.trim()) return own.textContent.trim();
    var walker = document.createTreeWalker(tile, NodeFilter.SHOW_TEXT);
    var node;
    while ((node = walker.nextNode())) {
      var text = node.nodeValue.trim();
      var parent = node.parentElement;
      if (!text || text.length > 60 || !parent) continue;
      if (parent.closest('button, [role="button"], [role="menu"], [role="tooltip"], i')) continue;
      if (hints.icon.test(typeof parent.className === 'string' ? parent.className : '')) continue;
      return text;
    }
    return '';
  }

  function silent(tile) {
    var icons = tile.querySelectorAll('i, [class*="symbol"], [class*="icon"]');
    for (var i = 0; i < icons.length; i++) {
      if (hints.silent.test(icons[i].textContent.trim())) return true;
    }
    var labelled = tile.querySelectorAll('[aria-label], [data-tooltip]');
    for (var j = 0; j < labelled.length; j++) {
      var label = labelled[j].getAttribute('aria-label') || labelled[j].getAttribute('data-tooltip') || '';
      if (labelled[j].tagName !== 'BUTTON' && hints.silentLabel.test(label)) return true;
    }
    return false;
  }

  // Whether the site shows a picture mirrored, as it does a camera's preview of
  // the person themselves and never a shared screen: a card mirrors what the
  // site mirrors, and nothing else.
  function flipped(video, tile) {
    var turned = false;
    for (var node = video; node && node !== tile.parentElement; node = node.parentElement) {
      var style = getComputedStyle(node);
      var matrix = /^matrix(3d)?\(([^,]+)/.exec(style.transform);
      if (matrix && parseFloat(matrix[2]) < 0) turned = !turned;
      if (/^-/.test(style.scale || '')) turned = !turned;
    }
    return turned;
  }

  // The picture a tile plays, if it plays one: a live video track that is
  // not muted for want of frames, in an element the site shows. A track the
  // page captured from a screen is a shared screen, whatever the tile says.
  function streamOf(tile) {
    var videos = tile.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var stream = videos[i].srcObject;
      var live = tracks(stream, 'video').filter(function (t) { return t.enabled && !t.muted; });
      if (live.length && shown(videos[i]) && getComputedStyle(videos[i]).display !== 'none') {
        var box = videos[i].getBoundingClientRect();
        var settings = live[0].getSettings ? live[0].getSettings() : {};
        return {
          stream: stream, area: box.width * box.height, remote: remote(stream, 'video'),
          mirrored: flipped(videos[i], tile), screen: !!settings.displaySurface
        };
      }
    }
    return null;
  }

  // Their photo while the camera is off: the tile's own image, once it has
  // loaded. Small images are icons.
  function pictureOf(tile) {
    var images = tile.querySelectorAll('img');
    var best = null, most = 0;
    for (var i = 0; i < images.length; i++) {
      var size = images[i].naturalWidth * images[i].naturalHeight;
      if (images[i].complete && images[i].naturalWidth >= 24 && size > most) { most = size; best = images[i]; }
    }
    return best;
  }

  // Drawn from the loaded image rather than named by its address: naming it
  // would load it again, a request the page never made.
  function paint(face, image) {
    var canvas = face.querySelector('canvas');
    var source = image ? image.currentSrc || image.src : '';
    if (!image) {
      if (canvas) canvas.remove();
      return;
    }
    if (!canvas) {
      canvas = document.createElement('canvas');
      canvas.width = canvas.height = 128;
      face.appendChild(canvas);
    }
    if (canvas.dataset.source === source) return;
    canvas.dataset.source = source;
    var side = Math.min(image.naturalWidth, image.naturalHeight);
    var drawing = canvas.getContext('2d');
    drawing.clearRect(0, 0, 128, 128);
    drawing.drawImage(image, (image.naturalWidth - side) / 2, (image.naturalHeight - side) / 2, side, side,
      0, 0, 128, 128);
  }

  function people() {
    var list = [], seen = {};
    var tiles = document.querySelectorAll(hints.tiles);
    for (var i = 0; i < tiles.length; i++) {
      var tile = tiles[i];
      var id = tile.getAttribute('data-participant-id');
      var video = streamOf(tile);
      if (!video && !shown(tile)) continue;
      var one = {
        id: id, name: nameOf(tile), video: video, picture: video ? null : pictureOf(tile),
        muted: silent(tile)
      };
      one.presentation = hints.presentation.test(one.name) || !!(video && video.screen);
      // A site may show the same person twice, large and in a strip: the
      // one with a moving picture is kept.
      if (seen[id]) {
        if (!seen[id].video && video) list[list.indexOf(seen[id])] = seen[id] = one;
        continue;
      }
      seen[id] = one;
      list.push(one);
    }
    if (list.length) return list;
    // A site that does not name its tiles: whoever arrived over the network.
    var videos = document.querySelectorAll('video');
    for (var j = 0; j < videos.length; j++) {
      if (!remote(videos[j].srcObject, 'video')) continue;
      var box = videos[j].getBoundingClientRect();
      list.push({
        id: 'video-' + j, name: '', picture: null, muted: false, presentation: false,
        video: { stream: videos[j].srcObject, area: box.width * box.height, remote: true }
      });
    }
    return list;
  }

  // What goes large: a shared screen, or the one picture the site itself
  // shows at twice the size of any other (a pinned or spotlit speaker).
  function stageOf(list) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].presentation && list[i].video) return list[i];
    }
    var moving = list.filter(function (one) { return one.video && one.video.remote; })
      .sort(function (a, b) { return b.video.area - a.video.area; });
    if (moving.length > 1 && moving[0].video.area >= 2 * moving[1].video.area) return moving[0];
    return null;
  }

  // MARK: - drawing it

  var colours = options.colours;
  var unit = options.unit;
  function u(points) { return (points * unit) + 'px'; }

  var sheet = document.getElementById('escale-meeting-page');
  if (!sheet) {
    sheet = document.createElement('style');
    sheet.id = 'escale-meeting-page';
    (document.head || root).appendChild(sheet);
  }
  // The site stays laid out and running beneath, unpainted. Its root is freed
  // of anything that would make it, rather than the viewport, the box the
  // window is drawn in.
  sheet.textContent = [
    'html.escale-meeting { overflow:hidden !important; background:' + colours.ground + ' !important;',
    'transform:none !important; filter:none !important; contain:none !important;',
    'perspective:none !important; will-change:auto !important }',
    'html.escale-meeting > body { visibility:hidden !important }',
    HOST + ' { all:initial; display:block !important; position:fixed !important;',
    'inset:0 !important; z-index:2147483647 !important; visibility:visible !important }'
  ].join('');

  var host = document.querySelector(HOST);
  if (!host) {
    host = document.createElement(HOST);
    host.attachShadow({ mode: 'open' });
    root.appendChild(host);
  }
  var shade = host.shadowRoot;
  shade.innerHTML = '<style>' + [
    ':host { font: ' + u(11) + '/1.25 -apple-system, system-ui, sans-serif; color:' + colours.ink + ' }',
    '.room { position:absolute; inset:0; display:flex; flex-direction:column; gap:' + u(6) + ';',
    'padding:' + u(8) + '; box-sizing:border-box; background:' + colours.ground + ' }',
    '.strip { display:flex; gap:' + u(6) + '; height:' + u(64) + '; flex:none }',
    '.strip .card { flex:1 1 0; max-width:' + u(120) + ' }',
    '.grid { flex:1; display:grid; gap:' + u(6) + '; min-height:0 }',
    '.stage { flex:1; min-height:0 }',
    '.card { position:relative; overflow:hidden; border-radius:' + u(8) + '; background:' + colours.card + ';',
    'display:flex; align-items:center; justify-content:center; min-width:0; min-height:0 }',
    '.card video { position:absolute; inset:0; width:100%; height:100%; object-fit:cover }',
    '.card.mirrored video { transform:scaleX(-1) }',
    // A shared screen is shown whole wherever it is, never cut to fill.
    '.stage video, .card.screen video { object-fit:contain }',
    '.face { width:' + u(36) + '; height:' + u(36) + '; border-radius:50%; overflow:hidden;',
    'display:flex; align-items:center; justify-content:center; font-size:' + u(15) + ';',
    'background:' + colours.face + '; color:' + colours.ink + ' }',
    '.grid .face { width:' + u(56) + '; height:' + u(56) + '; font-size:' + u(22) + ' }',
    '.face { position:relative }',
    '.face canvas { position:absolute; inset:0; width:100%; height:100% }',
    '.name { position:absolute; left:' + u(6) + '; right:' + u(22) + '; bottom:' + u(4) + ';',
    'white-space:nowrap; overflow:hidden; text-overflow:ellipsis; text-shadow:0 0 ' + u(3) + ' ' + colours.shade + ' }',
    '.muted { position:absolute; top:' + u(5) + '; right:' + u(5) + '; width:' + u(16) + '; height:' + u(16) + ';',
    'border-radius:50%; background:' + colours.alert + '; display:none; align-items:center; justify-content:center }',
    '.card.silent .muted { display:flex }',
    '.muted svg { width:' + u(10) + '; height:' + u(10) + ' }',
    '.more { font-size:' + u(15) + '; color:' + colours.faint + ' }'
  ].join('') + '</style><div class="room"></div>';
  var room = shade.querySelector('.room');

  var slash = '<svg viewBox="0 0 16 16" fill="none" stroke="' + colours.ink + '" stroke-width="1.6" '
    + 'stroke-linecap="round"><path d="M8 2.5a2 2 0 0 1 2 2v3M6 6v1.5a2 2 0 0 0 3.2 1.6M4.5 7.5a3.5 3.5 0 0 0 '
    + '5.6 2.8M11.5 7.5c0 .5-.1 1-.3 1.4M8 11v2.5M2.5 2.5l11 11"/></svg>';

  var cards = {};
  function card(one) {
    var made = cards[one.id];
    if (!made) {
      made = document.createElement('div');
      made.className = 'card';
      made.innerHTML = '<div class="face"><span class="initial"></span></div><span class="name"></span><span class="muted">' + slash + '</span>';
      cards[one.id] = made;
    }
    var video = made.querySelector('video');
    var stream = one.video && one.video.stream;
    if (stream) {
      if (!video) {
        video = document.createElement('video');
        video.muted = true; video.autoplay = true; video.playsInline = true;
        made.prepend(video);
      }
      if (video.srcObject !== stream) video.srcObject = stream;
      if (video.paused) video.play().catch(function () {});
    } else if (video) {
      video.srcObject = null;
      video.remove();
    }
    // A screen is never mirrored, even where the site draws it so: its words
    // would read backwards.
    made.classList.toggle('mirrored', !!(one.video && one.video.mirrored) && !one.presentation);
    made.classList.toggle('screen', one.presentation);
    made.classList.toggle('silent', one.muted);
    var face = made.querySelector('.face');
    face.style.display = stream ? 'none' : '';
    var letter = face.querySelector('.initial');
    var initial = one.picture ? '' : (one.name.trim()[0] || '').toUpperCase();
    if (letter.textContent !== initial) letter.textContent = initial;
    paint(face, one.picture);
    var label = made.querySelector('.name');
    if (label.textContent !== one.name) label.textContent = one.name;
    return made;
  }

  function more(count) {
    var made = document.createElement('div');
    made.className = 'card more';
    made.textContent = '+' + count;
    return made;
  }

  // The layout changes only when who is on show changes, so a card that
  // stays keeps its element, and its picture never restarts.
  var shape = '';
  function draw() {
    var list = people();
    var stage = stageOf(list);
    var others = list.filter(function (one) { return one !== stage; });
    var width = room.clientWidth - 2 * 8 * unit, height = room.clientHeight - 2 * 8 * unit;
    var fits, columns = 1;
    if (stage) {
      // Cards narrow to fit, down to 72 points, before any is folded into "+n".
      fits = Math.max(1, Math.floor((width + 6 * unit) / (78 * unit)));
    } else {
      columns = Math.min(3, Math.ceil(Math.sqrt(others.length || 1)));
      var rows = Math.max(1, Math.floor((height + 6 * unit) / (70 * unit)));
      fits = columns * rows;
    }
    var listed = others.length > fits ? others.slice(0, fits - 1) : others;
    var hidden = others.length - listed.length;
    var next = (stage ? 'stage:' + stage.id : 'grid:' + columns) + '|'
      + listed.map(function (one) { return one.id; }).join(',') + '|' + hidden;
    var drawn = listed.map(card);
    var big = stage ? card(stage) : null;
    if (next !== shape) {
      shape = next;
      var row = document.createElement('div');
      row.className = stage ? 'strip' : 'grid';
      if (!stage) {
        row.style.gridTemplateColumns = 'repeat(' + columns + ', minmax(0, 1fr))';
        row.style.gridAutoRows = 'minmax(0, 1fr)';
      }
      drawn.forEach(function (one) { row.appendChild(one); });
      if (hidden > 0) row.appendChild(more(hidden));
      room.replaceChildren();
      if (listed.length || hidden) room.appendChild(row);
      if (big) {
        big.classList.add('stage');
        room.appendChild(big);
      }
      for (var id in cards) {
        if (!room.contains(cards[id])) {
          var gone = cards[id].querySelector('video');
          if (gone) gone.srcObject = null;
          delete cards[id];
        }
      }
    }
    Object.keys(cards).forEach(function (id) {
      if (!big || cards[id] !== big) cards[id].classList.remove('stage');
    });
    window.__escaleMeeting = {
      stage: stage ? stage.name : null,
      cards: list.map(function (one) {
        return { name: one.name, video: !!one.video, picture: !!one.picture, muted: one.muted };
      }),
      more: hidden
    };
  }

  root.classList.add('escale-meeting');
  draw();
  clearInterval(window.__escaleMeetingWatch);
  window.__escaleMeetingWatch = setInterval(draw, 250);
  return 'floating';
})
