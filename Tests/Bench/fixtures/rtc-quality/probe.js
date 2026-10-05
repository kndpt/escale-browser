// Two native peers exchange a known tone and canvas over local ICE only. Keep
// bounded statistics, stop every producer, and expose failures to the runner
// instead of mistaking an established connection for good received media.
let peers = [], contexts = [], streams = [], oscillator, timer;
const result = {state: 'ready', samples: [], error: null};
window.probe = result;
const canvas = document.querySelector('#source');
const video = document.querySelector('#received');
const status = document.querySelector('#status');
if (new URLSearchParams(location.search).get('source') === 'display') {
  document.querySelector('#scope').textContent = 'Local display-capture test: select only this synthetic window. No microphone, camera or external server.';
  document.querySelector('#start').textContent = 'Share the synthetic window';
}

function stop() {
  clearInterval(timer);
  for (const peer of peers) peer.close();
  for (const stream of streams) for (const track of stream.getTracks()) track.stop();
  if (oscillator) { oscillator.stop(); oscillator = null; }
  for (const context of contexts) context.close();
  peers = []; contexts = []; streams = [];
  video.srcObject = null;
  if (result.state !== 'failed') result.state = 'stopped';
}

function fail(error) {
  result.error = String(error); result.state = 'failed'; stop();
  status.textContent = JSON.stringify(result, null, 2);
}

async function start() {
  document.querySelector('#start').disabled = true;
  result.state = 'starting';
  result.userAgent = navigator.userAgent;
  result.policy = new URLSearchParams(location.search).get('policy') || 'default';
  const audio = new AudioContext({sampleRate: 48000});
  contexts.push(audio);
  const resumed = audio.resume();
  const destination = audio.createMediaStreamDestination();
  oscillator = audio.createOscillator(); oscillator.frequency.value = 1000;
  const volume = audio.createGain(); volume.gain.value = 0.2;
  oscillator.connect(volume).connect(destination); oscillator.start();
  const drawing = canvas.getContext('2d');
  function paint() {
    drawing.fillStyle = 'white'; drawing.fillRect(0, 0, 1280, 720);
    drawing.fillStyle = 'black'; drawing.font = '24px monospace';
    for (let y = 40; y < 720; y += 40) drawing.fillText('Escale 0123456789 received detail', 20, y);
    drawing.fillStyle = 'red'; drawing.fillRect(1000, 100, 100, 100);
    drawing.fillStyle = 'blue'; drawing.fillRect(1000, 300, 100, 100);
  }
  paint();
  const capturing = new URLSearchParams(location.search).get('source') === 'display'
    ? navigator.mediaDevices.getDisplayMedia({video: true, audio: false})
    : canvas.captureStream(15);
  const [, picture] = await Promise.all([resumed, capturing]);
  if (result.state !== 'starting') { for (const track of picture.getTracks()) track.stop(); return; }
  result.audioState = audio.state;
  if (result.policy === 'detail') for (const track of picture.getVideoTracks()) track.contentHint = 'detail';
  result.videoHints = picture.getVideoTracks().map(track => track.contentHint);
  result.capture = picture.getVideoTracks().map(track => {
    const {width, height, frameRate, displaySurface} = track.getSettings();
    return {width, height, frameRate, displaySurface};
  });
  result.source = {width: canvas.width, height: canvas.height, requestedFrameRate: 15, redrawsPerSecond: 1};
  streams.push(destination.stream, picture);
  const sender = new RTCPeerConnection({iceServers: []});
  const receiver = new RTCPeerConnection({iceServers: []});
  peers.push(sender, receiver);
  const pending = [[], []];
  for (const [from, to, queue] of [[sender, receiver, pending[0]], [receiver, sender, pending[1]]]) {
    from.onicecandidate = ({candidate}) => {
      if (!candidate) return;
      if (to.remoteDescription) to.addIceCandidate(candidate).catch(fail);
      else queue.push(candidate);
    };
  }
  let analyser;
  receiver.ontrack = ({track}) => {
    const stream = new MediaStream([track]); streams.push(stream);
    if (track.kind === 'video') { video.srcObject = stream; video.play().catch(fail); }
    else {
      analyser = audio.createAnalyser(); analyser.fftSize = 8192;
      const silent = audio.createGain(); silent.gain.value = 0;
      audio.createMediaStreamSource(stream).connect(analyser).connect(silent).connect(audio.destination);
    }
  };
  for (const stream of [destination.stream, picture]) {
    for (const track of stream.getTracks()) {
      const sending = sender.addTrack(track, stream);
      if (track.kind === 'video' && result.policy === 'resolution') {
        const parameters = sending.getParameters();
        parameters.degradationPreference = 'maintain-resolution';
        await sending.setParameters(parameters);
      }
    }
  }
  await sender.setLocalDescription(await sender.createOffer());
  await receiver.setRemoteDescription(sender.localDescription);
  for (const candidate of pending[0]) await receiver.addIceCandidate(candidate);
  await receiver.setLocalDescription(await receiver.createAnswer());
  await sender.setRemoteDescription(receiver.localDescription);
  for (const candidate of pending[1]) await sender.addIceCandidate(candidate);
  if (result.state !== 'starting') return;
  const pixels = document.createElement('canvas'); pixels.width = 1280; pixels.height = 720;
  const read = pixels.getContext('2d', {willReadFrequently: true});
  let sampling = false;
  timer = setInterval(async () => {
    if (sampling || result.state === 'failed') return;
    sampling = true;
    try {
      paint(); // Keep the synthetic capture moving without an unbounded RAF.
      const sample = {time: performance.now(), connection: receiver.connectionState, width: video.videoWidth, height: video.videoHeight};
      if (analyser) {
        const spectrum = new Float32Array(analyser.frequencyBinCount);
        analyser.getFloatFrequencyData(spectrum);
        let peak = 0;
        for (let i = 1; i < spectrum.length; i++) if (spectrum[i] > spectrum[peak]) peak = i;
        sample.hz = peak * audio.sampleRate / analyser.fftSize;
        sample.db = Number.isFinite(spectrum[peak]) ? spectrum[peak] : null;
      }
      if (video.readyState >= 2) {
        read.drawImage(video, 0, 0, 1280, 720);
        sample.red = Array.from(read.getImageData(1050, 150, 1, 1).data);
        sample.blue = Array.from(read.getImageData(1050, 350, 1, 1).data);
      }
      // Only media/codec fields: omit candidate IPs, SDP and device identifiers.
      const reports = await receiver.getStats();
      if (result.state === 'stopped' || result.state === 'failed') return;
      sample.inbound = [];
      for (const report of reports.values()) if (report.type === 'inbound-rtp') {
        const fields = ['kind', 'packetsReceived', 'packetsLost', 'jitter', 'bytesReceived',
          'concealedSamples', 'totalSamplesReceived', 'framesDecoded', 'framesDropped', 'frameWidth', 'frameHeight'];
        const row = {};
        for (const field of fields) if (report[field] !== undefined) row[field] = report[field];
        row.codec = reports.get(report.codecId)?.mimeType;
        sample.inbound.push(row);
      }
      result.samples.push(sample);
      result.state = 'running';
      if (result.samples.length >= 30) { stop(); result.state = 'complete'; }
      status.textContent = JSON.stringify(result, null, 2);
    } catch (error) { fail(error); }
    finally { sampling = false; }
  }, 1000);
}
document.querySelector('#start').onclick = () => start().catch(fail);
document.querySelector('#stop').onclick = stop;
addEventListener('pagehide', stop, {once: true});
