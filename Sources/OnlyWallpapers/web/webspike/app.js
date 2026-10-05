(function() {
  var params = new URLSearchParams(window.location.search);
  var nofilter = params.get('nofilter') === '1';
  var clearMode = params.get('clear') === '1';

  if (nofilter) { document.body.classList.add('nofilter'); }
  if (clearMode) { document.body.classList.add('clear-mode'); }

  if (clearMode) {
    return;
  }

  var video = document.getElementById('bg');
  var presentedFrames = 0;
  var loopCount = 0;
  var lastTime = 0;
  var useRVFC = false;
  var rvfcCount = 0;

  video.muted = true;

  function frameCallback(now, meta) {
    presentedFrames++;
    rvfcCount++;
    video.requestVideoFrameCallback(frameCallback);
  }

  if (typeof video.requestVideoFrameCallback === 'function') {
    useRVFC = true;
    video.requestVideoFrameCallback(frameCallback);
  }

  video.addEventListener('timeupdate', function() {
    if (!useRVFC) {
      presentedFrames++;
    }
    var ct = video.currentTime;
    if (ct < lastTime && lastTime > 0) {
      loopCount++;
    }
    lastTime = ct;
  });

  function tryPlay() {
    if (video.paused) {
      video.play().catch(function() {});
    }
  }

  video.addEventListener('loadeddata', tryPlay);
  video.addEventListener('canplay', tryPlay);
  tryPlay();

  function sendTelemetry() {
    var quality = (typeof video.getVideoPlaybackQuality === 'function')
      ? video.getVideoPlaybackQuality().totalVideoFrames
      : -1;
    var msg = {
      presentedFrames: presentedFrames,
      currentTime: video.currentTime,
      paused: video.paused,
      ended: video.ended,
      readyState: video.readyState,
      visibility: document.visibilityState,
      loops: loopCount,
      totalVideoFrames: quality,
      usedRVFC: useRVFC
    };
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.owspike) {
      window.webkit.messageHandlers.owspike.postMessage(msg);
    }
  }

  setInterval(sendTelemetry, 1000);
})();
