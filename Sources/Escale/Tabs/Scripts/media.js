/*
Installed only after WebKit detects playback (or a one-shot leave check), in the
main page world so Media Session metadata remains readable. No handler wrapping,
network, artwork, timeupdate listener or polling. One selected media element,
32 candidates maximum, event snapshots coalesced over 150 ms, removed on stop.
Inaccessible sources keep return to source; native playback state determines
whether WebKit's tab-wide pause is available for frames or Web Audio.
Site track buttons are used only when visible and enabled; a bounded postcondition
check rejects commands that the site ignores, instead of claiming success.
Spotify can keep its audio outside the document. Its visible player controls
then provide a separate target, without treating an unrelated element as audio.
*/
window.__escaleMedia?.stop();
let stopped = false, timer = null, revision = 0, last = '', chosen = null;
let number = 0;
let audible = nativeAudio;
const spotifyPage = location.hostname === 'open.spotify.com';
const identities = new WeakMap(), blocked = new Set(), waits = new Map();
const events = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange', 'error'];
function media() {
    const audio = document.getElementsByTagName('audio'), video = document.getElementsByTagName('video');
    if (audio.length + video.length > 32) return null;
    const ready = [...audio, ...video].filter(m => m.readyState > 0);
    const live = ready.filter(m => !m.paused && !m.ended);
    if (live.length === 1) chosen = live[0];
    else if (live.length > 1) return null;
    if (chosen && !chosen.isConnected) chosen = null;
    // A paused main-document element is not the source of an audible iframe.
    // It is a candidate only when reopening a previously dismissed pause.
    if (!chosen && allowPaused && ready.length === 1) chosen = ready[0];
    return chosen;
}
function usable(b) {
    return b && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && b.getClientRects().length &&
        getComputedStyle(b).visibility !== 'hidden' ? b : null;
}
function track(action) {
    let selector;
    if (location.hostname === 'www.youtube.com' || location.hostname === 'youtube.com')
        selector = action === 'next' ? '.ytp-next-button' : '.ytp-prev-button';
    if (location.hostname === 'open.spotify.com')
        selector = action === 'next' ? '[data-testid="control-button-skip-forward"]' : '[data-testid="control-button-skip-back"]';
    if (!selector) return null;
    return usable(document.querySelector(selector));
}
function spotifyVolume() {
    const input = usable(document.querySelector('[data-testid="volume-bar"] input[type="range"], input[type="range"][aria-label="Volume" i]'));
    if (!input) return null;
    const min = input.min === '' ? 0 : Number(input.min), max = input.max === '' ? 100 : Number(input.max);
    const value = Number(input.value);
    return Number.isFinite(min) && Number.isFinite(max) && Number.isFinite(value) && max > min && value >= min && value <= max
        ? {input, min, max, value:(value-min)/(max-min)} : null;
}
function spotifyPosition() {
    const text = document.querySelector('[data-testid="playback-position"]')?.textContent || '';
    if (!/^\d{1,3}:\d{2}(?::\d{2})?$/.test(text.trim())) return null;
    return text.trim().split(':').reduce((seconds, part)=>seconds*60+Number(part),0);
}
function spotify() {
    if (!spotifyPage) return null;
    const button = usable(document.querySelector('[data-testid="control-button-playpause"]'));
    if (!button) return null;
    const session = navigator.mediaSession, title = (session?.metadata?.title || document.title).slice(0,256);
    const label = button.getAttribute('aria-label') || '';
    // The site's transport label describes the offered action. Media Session
    // and native audibility cover other locales without assuming a fake pause.
    const playing = /^pause\b/i.test(label) ? true : /^(play|lecture|lire)\b/i.test(label) ? false :
        session?.playbackState === 'playing' ? true : session?.playbackState === 'paused' ? false : audible;
    const volume = spotifyVolume(), actions = [playing ? 'pause' : 'play'];
    for (const action of ['previous','next']) if (track(action)) actions.push(action);
    if (volume) actions.push('volume');
    return {key:`spotify:${title}:${(session?.metadata?.artist || '').slice(0,256)}`, title, playing,
        muted:volume?.value === 0, volume:volume?.value, actions:actions.filter(a=>!blocked.has(a))};
}
function snapshot() {
    const m = media();
    if (!m) return spotify() || {key:'', title:'', playing:true, muted:false, actions:['pause']};
    if (!identities.has(m)) identities.set(m, ++number);
    const title = (navigator.mediaSession?.metadata?.title || '').slice(0,256);
    const key = `${identities.get(m)}:${m.currentSrc.slice(0,512)}:${title}`;
    const actions = [m.paused ? 'play' : 'pause', 'volume'];
    for (const action of ['previous','next']) if (track(action)) actions.push(action);
    return {key, title, playing:!m.paused && !m.ended, ended:m.ended || !!m.error || m.readyState === 0,
        video:m instanceof HTMLVideoElement && m.readyState >= 2,
        muted:m.muted || m.volume === 0, volume:m.volume, actions:actions.filter(a=>!blocked.has(a))};
}
function send() {
    clearTimeout(timer);timer = null;
    if (stopped) return;
    const state = snapshot(), encoded = JSON.stringify(state);
    if (encoded === last) return;
    last = encoded;
    window.webkit.messageHandlers[handler].postMessage({...state,token,revision:++revision});
}
function schedule() { if (!stopped && timer === null) timer=setTimeout(send,150); }
function event(e) {
    if (!(e.target instanceof HTMLMediaElement)) return;
    if (e.type === 'play' || e.type === 'playing') { chosen = e.target; blocked.clear(); }
    schedule();
}
function volumeEvent(e) {
    if (spotifyPage && e.target instanceof HTMLInputElement &&
        e.target.type === 'range') schedule();
}
function delay(ms) { return new Promise(resolve=>{ const id=setTimeout(()=>{waits.delete(id);resolve();},ms);waits.set(id,resolve); }); }
const observer = new MutationObserver(schedule);
observer.observe(document, {subtree:true, childList:true, attributes:true,
    attributeFilter:spotifyPage ? ['disabled','aria-disabled','aria-label'] : ['disabled','aria-disabled']});
events.forEach(e=>document.addEventListener(e,event,true));
if (spotifyPage) {
    document.addEventListener('input',volumeEvent,true);
    document.addEventListener('change',volumeEvent,true);
}
const api = {
    sound(expected, playing) {
        if (stopped || expected !== token) return;
        if (playing && !audible) blocked.clear();
        audible = playing;
        schedule();
    },
    stop(expected) {
        if (expected && expected !== token) return;
        stopped=true; clearTimeout(timer); observer.disconnect();
        events.forEach(e=>document.removeEventListener(e,event,true));
        document.removeEventListener('input',volumeEvent,true);
        document.removeEventListener('change',volumeEvent,true);
        for (const [id,resolve] of waits) {clearTimeout(id);resolve();} waits.clear();
        chosen=null;
        if (window.__escaleMedia === api) delete window.__escaleMedia;
    },
    video() {
        const m = media();
        return !stopped && m instanceof HTMLVideoElement && !m.ended && m.readyState >= 2 ? m : null;
    },
    async command(expected, action, key, value) {
        if (stopped || expected !== token) return false;
        const before=snapshot(), m=media();
        if (key !== before.key || !before.actions.includes(action)) return false;
        if (!m && key.startsWith('spotify:')) {
            const position = spotifyPosition();
            try {
                if (action === 'volume') {
                    const volume = spotifyVolume(); if (!volume) return false;
                    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
                    if (!setter) return false;
                    setter.call(volume.input,String(volume.min + Math.max(0,Math.min(1,value))*(volume.max-volume.min)));
                    volume.input.dispatchEvent(new Event('input',{bubbles:true}));
                    volume.input.dispatchEvent(new Event('change',{bubbles:true}));
                } else {
                    const button = action === 'play' || action === 'pause'
                        ? usable(document.querySelector('[data-testid="control-button-playpause"]')) : track(action);
                    if (!button) return false;
                    button.click();
                }
                for (let i=0;i<10 && !stopped;i++) {
                    await delay(200);
                    if (stopped) return false;
                    const now = snapshot();
                    const ok = now.key !== '' && (action === 'play' ? now.playing : action === 'pause' ? !now.playing :
                        action === 'volume' ? Number.isFinite(now.volume) && Math.abs(now.volume-value)<0.01 :
                        now.key !== key || (action === 'previous' && position !== null && spotifyPosition() !== null && spotifyPosition() < position-1));
                    if (ok) {send();return true;}
                }
            } catch (_) { /* A disappearing control is a refused command. */ }
            if (!stopped) {blocked.add(action);send();}
            return false;
        }
        if (!m) return false;
        try {
            if (action === 'play') await Promise.race([m.play(),delay(2000).then(()=>{throw new Error('timeout');})]);
            else if (action === 'pause') m.pause();
            else if (action === 'volume') { m.volume=Math.max(0,Math.min(1,value));m.muted=false; }
            else {
                const button=track(action);if (!button) return false;
                const position=m.currentTime;button.click();
                for (let i=0;i<10 && !stopped;i++) {
                    await delay(200);
                    const now=snapshot();
                    if (now.key !== key || (action === 'previous' && m.currentTime < position-1)) {send();return true;}
                }
                if (!stopped) {blocked.add(action);send();} return false;
            }
            await delay(150);
            if (stopped) return false;
            const ok=action === 'play' ? !m.paused : action === 'pause' ? m.paused : Math.abs(m.volume-value)<0.01;
            if (!ok) blocked.add(action);
            send();return ok;
        } catch (_) { if (!stopped) {blocked.add(action);send();} return false; }
    }
};
window.__escaleMedia=api;
send();
return true;
