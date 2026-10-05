/*
Runs inside WebKit's own Web Inspector frontend page, never in a web page
(Calls.swift). It listens to the frontend's network model at class level, so
the resources of every frame and worker target report here, and posts compact
rows to Escale. A row carries no body: headers, the sent body and the
response are read on request, by identifier, and cut before they leave.
Events of one backend message arrive in the same task; a microtask sends them
together without a timer, which this hidden page would throttle.

Paused, it reports only the exchanges it already knew, so a call under way
still finishes; one first seen while paused is never reported, even when its
events come after the resumption. Clearing forgets every exchange known so
far the same way, and numbers the rows sent since (the epoch), so a message
already on its way cannot bring a cleared row back.

The search reads response bodies from WebKit's backend here, in the frontend's
process, and sends Escale only the calls that match with a short excerpt.
What it read is kept for the next search within declared limits (characters
per response and in all), oldest read let go first, and dropped with its row,
when the search is emptied, on clearing and on stopping. A newer search stops an older one between reads.
*/
(() => {
    if (window.__escaleCalls) return {installed: false, reason: "already"};
    if (typeof WI === "undefined" || !WI.Resource || !WI.Frame || !WI.Target || !WI.networkManager)
        return {installed: false, reason: "WebKit's network model is missing"};
    const limit = 500;
    const setup = window.__escaleCallsSetup || {};
    delete window.__escaleCallsSetup;
    let epoch = typeof setup.epoch === "number" ? setup.epoch : 0;
    let paused = setup.paused === true;
    // Cleared before this reconnection: what WebKit knew before it, rebuilt
    // for the new session without a sending time, is not listed again.
    const cleared = setup.cleared === true;
    const post = rows => window.webkit.messageHandlers.escaleCalls.postMessage({rows, epoch});
    const ids = new WeakMap();
    const live = new Map();
    // Exchanges first seen while paused, or cleared: never reported again.
    const skipped = new WeakSet();
    // Bodies read by the search, by identifier: {kind, text, cut}.
    const bodies = new Map();
    let held = 0;
    let next = 0;
    // Rows waiting for the microtask, by identifier: a later event for the
    // same exchange replaces its row in place, and a burst keeps the newest
    // `limit`, as the list itself would.
    let pending = new Map();
    let scheduled = false;
    const text = (value, max) => typeof value === "string" ? value.slice(0, max) : null;
    const number = value => typeof value === "number" && isFinite(value) ? value : null;
    const kind = type => typeof type === "string" ? type.replace(/^resource-type-/, "") : null;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    // At most `max` UTF-8 bytes, cut at a character: a slice of `max` code
    // units first (three bytes each at most), then trimmed if needed.
    function bytes(value, max) {
        const head = value.slice(0, max);
        const encoded = encoder.encode(head);
        if (encoded.length <= max) return {text: head, cut: head.length < value.length};
        let end = max;
        while (end > 0 && (encoded[end] & 0xC0) === 0x80) end--;
        return {text: decoder.decode(encoded.subarray(0, end)), cut: true};
    }

    // Resources are found again by identifier, held weakly: the frontend
    // decides their lifetime. The map keeps the order in which calls were
    // first seen, as the list in Escale does, so both let go of the same
    // oldest call and a row still listed can always be read.
    function key(resource) {
        let id = ids.get(resource);
        if (!id) { id = resource.requestIdentifier || ("local-" + (++next)); ids.set(resource, id); }
        const known = live.has(id);
        live.set(id, new WeakRef(resource));
        if (!known && live.size > limit) forget(live.keys().next().value);
        return id;
    }
    function forget(id) {
        live.delete(id);
        const body = bodies.get(id);
        if (body) { held -= body.text ? body.text.length : 0; bodies.delete(id); }
    }
    function row(resource) {
        const target = resource.target || null;
        const frame = resource.parentFrame || null;
        const data = resource.requestData;
        return {
            id: key(resource),
            url: text(resource.url, 2048), method: resource.requestMethod || null,
            type: kind(resource.type), status: number(resource.statusCode), statusText: text(resource.statusText, 128),
            mime: text(resource.mimeType, 128), finished: !!resource.finished, failed: !!resource.failed,
            canceled: !!resource.canceled, failure: text(resource.failureReasonText, 256),
            source: resource.responseSource ? text(resource.responseSource.description, 32) : null,
            target: target ? (target.type || null) : null, targetName: target ? text(target.displayName, 256) : null,
            frame: frame ? text(frame.url, 512) : null, mainFrame: frame ? !!(frame.isMainFrame() || frame === WI.networkManager.mainFrame) : null,
            requestBytes: typeof data === "string" ? data.length : null,
            sent: number(resource.requestSentTimestamp), received: number(resource.responseReceivedTimestamp),
            ended: number(resource.finishedOrFailedTimestamp),
            size: number(resource.size), transfer: number(resource.networkTotalTransferSize),
            redirects: resource.redirects ? resource.redirects.length : 0,
            // WebKit's record of a load made before anyone listened (the
            // frame tree it rebuilds on connecting) has no sending time.
            early: number(resource.requestSentTimestamp) === null
        };
    }
    function queue(resource) {
        if (!resource || skipped.has(resource)) return;
        if (!ids.has(resource) && (paused || cleared && number(resource.requestSentTimestamp) === null)) {
            skipped.add(resource);
            return;
        }
        const next = row(resource);
        pending.set(next.id, next);
        if (pending.size > limit) pending.delete(pending.keys().next().value);
        if (scheduled) return;
        scheduled = true;
        queueMicrotask(() => {
            scheduled = false;
            const rows = [...pending.values()];
            pending = new Map();
            if (window.__escaleCalls) post(rows);
        });
    }
    const listeners = [];
    function listen(owner, event, pick) {
        if (!event) return;
        const handler = e => queue(pick(e));
        owner.addEventListener(event, handler);
        listeners.push([owner, event, handler]);
    }
    listen(WI.Frame, WI.Frame.Event.ResourceWasAdded, e => e.data && e.data.resource);
    listen(WI.Target, WI.Target.Event.ResourceAdded, e => e.data && e.data.resource);
    listen(WI.Resource, WI.Resource.Event.ResponseReceived, e => e.target);
    listen(WI.Resource, WI.Resource.Event.LoadingDidFinish, e => e.target);
    listen(WI.Resource, WI.Resource.Event.LoadingDidFail, e => e.target);
    listen(WI.Resource, WI.Resource.Event.RequestDataDidChange, e => e.target);

    const byId = id => { const ref = live.get(id); return ref ? ref.deref() || null : null; };
    const pairs = (headers, max) => Object.entries(headers || {}).slice(0, 100)
        .map(([name, value]) => [String(name).slice(0, 256), String(value).slice(0, max)]);
    // Why WebKit has no body to give, in words the panel can show as they
    // are, and of which kind for the search: none exists, not yet, or WebKit
    // does not give it.
    function why(resource) {
        const type = kind(resource.type);
        if (resource.failed && !resource.canceled) return ["none", "The request failed; WebKit keeps no response body."];
        if (resource.canceled) return ["none", "The request was canceled; WebKit keeps no response body."];
        if (type === "beacon" || type === "ping") return ["none", "WebKit keeps no response body for a beacon."];
        if (type === "websocket") return ["none", "WebSocket frames are not collected; the handshake has no body."];
        if (!resource.finished) return ["loading", "loading"];
        const target = resource.target;
        if (!target || !target.NetworkAgent) return ["unavailable", "WebKit does not expose response bodies of dedicated worker requests."];
        if (!resource.requestIdentifier) return ["unavailable", "WebKit gave this resource no request identifier."];
        return null;
    }
    const gone = "This call belongs to an earlier inspection session.";
    // WebKit answers an empty body with an error rather than "".
    const empty = resource => resource.finished && resource.size === 0;
    // The backend agent is asked directly so the frontend keeps no copy in
    // its own content cache. The deadline goes as soon as WebKit answers.
    function fetchBody(resource) {
        let deadline;
        return Promise.race([
            resource.target.NetworkAgent.getResponseBody(resource.requestIdentifier),
            new Promise((_, fail) => { deadline = setTimeout(() => fail(new Error("WebKit did not answer within 10 seconds.")), 10000); })
        ]).finally(() => clearTimeout(deadline));
    }

    // A body for the search, from what is held or from WebKit, and kept when
    // it is text: at most `per` characters of it, `total` in all. A pass
    // ended while WebKit answered (a newer search, the field emptied, Clear)
    // keeps nothing.
    async function searchable(id, per, total, token) {
        const kept = bodies.get(id);
        if (kept) { bodies.delete(id); bodies.set(id, kept); return kept; }
        const resource = byId(id);
        if (!resource) return {kind: "unavailable", reason: gone};
        const reason = why(resource);
        if (reason) return {kind: reason[0], reason: reason[1]};
        let reply;
        try { reply = await fetchBody(resource); } catch (error) {
            if (!empty(resource)) return {kind: "unavailable", reason: String(error && error.message || error).slice(0, 256)};
            reply = {body: "", base64Encoded: false};
        }
        // Cleared or let go while WebKit answered: nothing is kept for it.
        if (byId(id) !== resource) return {kind: "unavailable", reason: gone};
        if (asked !== token) return {kind: "unavailable", reason: "superseded"};
        let body;
        if (reply.base64Encoded) body = {kind: "binary"};
        else {
            const whole = reply.body || "";
            // A slice would keep the whole body alive behind it: a cut part
            // is copied into a string of its own.
            const cut = whole.length > per;
            body = {kind: "text", text: cut ? decoder.decode(encoder.encode(whole.slice(0, per))) : whole, cut};
        }
        bodies.set(id, body);
        held += body.text ? body.text.length : 0;
        trim(total, id);
        return body;
    }
    // The oldest read go first until `total` characters are held.
    function trim(total, keep) {
        for (const [id, value] of bodies) {
            if (held <= total) break;
            if (id === keep) continue;
            held -= value.text ? value.text.length : 0;
            bodies.delete(id);
        }
    }
    const excerpt = value => value.replace(/\s+/g, " ");
    let asked = 0;

    const listening = listeners.length;
    window.__escaleCalls = {
        stop() {
            for (const [owner, event, handler] of listeners) owner.removeEventListener(event, handler);
            listeners.length = 0; live.clear(); pending = new Map(); bodies.clear(); held = 0; asked++;
            delete window.__escaleCalls;
            return true;
        },
        // Paused, exchanges not known yet are let go for good.
        record(on) { paused = !on; return paused; },
        // The search is over: what it read goes, the rows stay.
        drop() { bodies.clear(); held = 0; asked++; return true; },
        // Everything known so far is forgotten; rows sent after carry `next`.
        clear(next) {
            for (const ref of live.values()) { const resource = ref.deref(); if (resource) skipped.add(resource); }
            live.clear(); pending = new Map(); bodies.clear(); held = 0; asked++;
            epoch = next;
            return true;
        },
        // The calls of `list` (identifiers, newest first) whose response
        // contains `needle`, whatever its case, each with the text around its
        // first occurrence, and what became of the others. `readers` bodies
        // are read from WebKit at once; a newer search ends this one.
        async search(needle, list, per, total, readers, around) {
            const token = ++asked;
            trim(total, null);
            const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
            const pattern = new RegExp(escaped, "iu");
            const matches = [], counts = {text: 0, cut: 0, binary: 0, none: 0, unavailable: 0, loading: 0}, reasons = {};
            let at = 0;
            async function reader() {
                while (at < list.length && asked === token) {
                    const id = list[at++];
                    const body = await searchable(id, per, total, token);
                    if (asked !== token) return;
                    if (body.kind !== "text") {
                        counts[body.kind]++;
                        if (body.reason && body.kind === "unavailable") reasons[body.reason] = (reasons[body.reason] || 0) + 1;
                        continue;
                    }
                    counts[body.cut ? "cut" : "text"]++;
                    const found = pattern.exec(body.text);
                    if (!found) continue;
                    const start = found.index, end = start + found[0].length;
                    matches.push({id, before: excerpt(body.text.slice(Math.max(0, start - around), start)).trimStart(),
                                  hit: found[0], after: excerpt(body.text.slice(end, end + around * 2)).trimEnd(),
                                  head: start <= around, tail: end + around * 2 >= body.text.length && !body.cut});
                }
            }
            await Promise.all(Array.from({length: readers}, reader));
            if (asked !== token) return {superseded: true};
            return {matches, counts, reasons, held};
        },
        detail(id, max) {
            const resource = byId(id);
            if (!resource) return {error: gone};
            const data = resource.requestData;
            const sent = typeof data === "string" ? bytes(data, max) : null;
            return {
                row: row(resource),
                requestHeaders: pairs(resource.requestHeaders, 4096),
                responseHeaders: pairs(resource.responseHeaders, 4096),
                requestType: text(resource.requestDataContentType, 128),
                requestBody: sent ? sent.text : null,
                requestLength: typeof data === "string" ? data.length : null,
                requestCut: sent ? sent.cut : false,
                redirects: (resource.redirects || []).slice(0, 10).map(r => ({url: text(r.url, 2048), status: number(r.statusCode)})),
                initiator: resource.initiatorSourceCodeLocation && resource.initiatorSourceCodeLocation.sourceCode
                    ? text(resource.initiatorSourceCodeLocation.sourceCode.url, 512) : null
            };
        },
        // The reply is cut before it is posted.
        async body(id, max) {
            const resource = byId(id);
            if (!resource) return {unavailable: gone};
            const reason = why(resource);
            if (reason) return {unavailable: reason[1]};
            try {
                const reply = await fetchBody(resource).catch(error => { if (empty(resource)) return {body: ""}; throw error; });
                const body = reply.body || "";
                const part = bytes(body, max);
                // Base64 carries three bytes in four characters, less its padding.
                const padding = body.endsWith("==") ? 2 : body.endsWith("=") ? 1 : 0;
                return {length: body.length, base64: !!reply.base64Encoded, body: part.text, cut: part.cut,
                        decoded: reply.base64Encoded ? Math.floor(body.length / 4) * 3 - padding : null};
            } catch (error) {
                return {unavailable: String(error && error.message || error).slice(0, 256)};
            }
        }
    };
    // Documents WebKit knew before the collection began.
    // Paused, or once cleared, they are not listed, and never will be.
    const existing = [];
    for (const frame of WI.networkManager.frames || []) {
        for (const resource of [frame.mainResource, ...(frame.resourceCollection || [])]) {
            if (!resource) continue;
            if (paused || cleared) skipped.add(resource); else existing.push(row(resource));
        }
    }
    if (existing.length) post(existing.slice(-limit));
    return {installed: true, listeners: listening, existing: existing.length, targets: (WI.targets || []).length};
})()
