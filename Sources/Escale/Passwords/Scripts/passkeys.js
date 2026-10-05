/*
Passkey requests use the page's credential prototypes and relay to Escale.
The handler name is passed as JSON; the page's abort and extension paths stay in this document.
*/
(function (options) {
  if (window.__escalePasskeys || !window.PublicKeyCredential || !window.CredentialsContainer) return;
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers[options.handler];
  if (!handler) return;
  Object.defineProperty(window, '__escalePasskeys', { value: true });
  var proto = CredentialsContainer.prototype;
  var nativeGet = proto.get, nativeCreate = proto.create;
  var refused = 'The operation either timed out or was not allowed.';

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected an ArrayBuffer or a view of one.');
  }
  function encode(source) {
    var b = bytes(source), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(text) {
    var s = (text || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  function descriptors(list) {
    return Array.prototype.map.call(list || [], function (c) {
      return { id: encode(c.id), transports: Array.prototype.slice.call(c.transports || []) };
    });
  }
  function aborted(signal) {
    return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
  }
  function define(target, values, hidden) {
    Object.keys(values).forEach(function (k) {
      Object.defineProperty(target, k, { value: values[k], enumerable: !hidden, configurable: true });
    });
    return target;
  }

  function credential(reply, extensions) {
    var response, made = reply.kind === 'create';
    if (made) {
      response = Object.create(AuthenticatorAttestationResponse.prototype);
      define(response, { clientDataJSON: decode(reply.clientDataJSON), attestationObject: decode(reply.attestationObject) });
      define(response, {
        getTransports: function () { return (reply.transports || []).slice(); },
        getAuthenticatorData: function () { return decode(reply.authenticatorData); },
        getPublicKey: function () { return reply.publicKey ? decode(reply.publicKey) : null; },
        getPublicKeyAlgorithm: function () { return reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7; }
      }, true);
    } else {
      response = Object.create(AuthenticatorAssertionResponse.prototype);
      define(response, {
        clientDataJSON: decode(reply.clientDataJSON),
        authenticatorData: decode(reply.authenticatorData),
        signature: decode(reply.signature),
        userHandle: reply.userHandle ? decode(reply.userHandle) : null
      });
    }
    // A passkey from the Mac is always one the site can find without
    // naming it; the site may have asked whether it is.
    var results = {};
    if (made && extensions && extensions.credProps && reply.attachment === 'platform') results.credProps = { rk: true };
    var attachment = reply.attachment || null;
    var json = { id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: results };
    json.response = made
      ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData,
          transports: (reply.transports || []).slice(), publicKeyAlgorithm: reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7 }
      : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature };
    if (made && reply.publicKey) json.response.publicKey = reply.publicKey;
    if (!made && reply.userHandle) json.response.userHandle = reply.userHandle;
    var result = Object.create(PublicKeyCredential.prototype);
    define(result, { id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: attachment, response: response });
    return define(result, {
      getClientExtensionResults: function () { return JSON.parse(JSON.stringify(results)); },
      toJSON: function () { return JSON.parse(JSON.stringify(json)); }
    }, true);
  }

  function send(request, signal, extensions) {
    if (signal && signal.aborted) return Promise.reject(aborted(signal));
    request.token = Math.random().toString(36).slice(2);
    return new Promise(function (resolve, reject) {
      if (signal) signal.addEventListener('abort', function () {
        handler.postMessage({ kind: 'cancel', token: request.token });
        reject(aborted(signal));
      }, { once: true });
      handler.postMessage(request).then(function (reply) {
        if (!reply || reply.error) {
          var name = (reply && reply.error) || 'NotAllowedError';
          var message = (reply && reply.message) || refused;
          return reject(name === 'TypeError' ? new TypeError(message) : new DOMException(message, name));
        }
        resolve(credential(reply, extensions));
      }, function () { reject(new DOMException(refused, 'NotAllowedError')); });
    });
  }

  function replace(target, name, value) {
    try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
  }

  replace(proto, 'get', function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    var signal = options.signal, pk = options.publicKey, request;
    if (options.mediation === 'conditional') {
      // Nothing of the Mac's is offered under the field yet: the request
      // waits, as it does while nobody picks a passkey, until the page
      // lets it go.
      return new Promise(function (resolve, reject) {
        if (!signal) return;
        if (signal.aborted) return reject(aborted(signal));
        signal.addEventListener('abort', function () { reject(aborted(signal)); }, { once: true });
      });
    }
    try {
      request = {
        kind: 'get', challenge: encode(pk.challenge), rpId: pk.rpId || null,
        allowCredentials: descriptors(pk.allowCredentials),
        userVerification: pk.userVerification || 'preferred'
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, signal, pk.extensions);
  });

  replace(proto, 'create', function create(options) {
    if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
    var pk = options.publicKey, selection = pk.authenticatorSelection || {}, request;
    // A passkey made quietly after a password sign-in: not something
    // this browser does yet, so the site hears no, as it would if you had.
    if (options.mediation === 'conditional') return Promise.reject(new DOMException(refused, 'NotAllowedError'));
    try {
      request = {
        kind: 'create', challenge: encode(pk.challenge),
        rp: { id: (pk.rp && pk.rp.id) || null },
        user: { id: encode(pk.user.id), name: String(pk.user.name), displayName: pk.user.displayName ? String(pk.user.displayName) : '' },
        algorithms: Array.prototype.map.call(pk.pubKeyCredParams || [], function (p) { return p.alg; }),
        excludeCredentials: descriptors(pk.excludeCredentials),
        authenticatorAttachment: selection.authenticatorAttachment || null,
        residentKey: selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged'),
        userVerification: selection.userVerification || 'preferred',
        attestation: pk.attestation || 'none'
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, options.signal, pk.extensions);
  });

  // A password manager that keeps passkeys — 1Password, Bitwarden — puts
  // its own get and create on navigator.credentials, or asks from its own
  // script, and offers its passkeys under the name field to the sites that
  // ask for them that way. Once one is there, pages hear the field can.
  var claimed = false;
  function extensionAnswers() {
    if (claimed) return true;
    try {
      if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
      else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
    } catch (e) {}
    return claimed;
  }

  // What this browser can and can't do, for the pages that ask first:
  // passkeys from the Mac, a phone or a key — not yet under the field,
  // and none of what WebKit would have answered for itself.
  var P = PublicKeyCredential;
  replace(P, 'isUserVerifyingPlatformAuthenticatorAvailable', function () { return Promise.resolve(true); });
  replace(P, 'isConditionalMediationAvailable', function () { return Promise.resolve(extensionAnswers()); });
  var nativeCapabilities = P.getClientCapabilities;
  if (typeof nativeCapabilities === 'function') {
    replace(P, 'getClientCapabilities', function () {
      var field = extensionAnswers();
      function ours(c) {
        c = Object.assign({}, c);
        Object.keys(c).forEach(function (k) { if (k.indexOf('extension:') === 0 && k !== 'extension:credProps') c[k] = false; });
        return Object.assign(c, {
          conditionalCreate: false, conditionalGet: field, conditionalMediation: field, relatedOrigins: false,
          signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false,
          hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true
        });
      }
      return nativeCapabilities.call(P).then(ours, function () { return ours({}); });
    });
  }
})
