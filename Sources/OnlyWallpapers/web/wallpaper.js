(function () {
  function num(x) { return typeof x === "number" && isFinite(x); }

  function applyGeometry(g) {
    var stage = document.getElementById("stage");
    if (!stage) return;
    if (g && num(g.stageW) && num(g.stageH) && g.stageW > 0 && g.stageH > 0 && num(g.offX) && num(g.offY)) {
      stage.style.left = (-g.offX) + "px";
      stage.style.top = (-g.offY) + "px";
      stage.style.width = g.stageW + "px";
      stage.style.height = g.stageH + "px";
    }
    var r = stage.getBoundingClientRect();
    window.__wallpaperApplied = { left: r.left, top: r.top, width: r.width, height: r.height };
  }

  window.__applyWallpaperGeometry = applyGeometry;
  applyGeometry(window.__wallpaper);
})();

(function () {
  function clamp(x, lo, hi, def) {
    if (typeof x !== 'number' || !isFinite(x)) return def;
    return Math.min(Math.max(x, lo), hi);
  }
  function applyFraming(cfg) {
    var bg = document.getElementById('bg'); if (!bg) return;
    var z  = clamp(cfg && cfg.zoom, 1, 2, 1);
    var px = clamp(cfg && cfg.panX, -1, 1, 0);
    var py = clamp(cfg && cfg.panY, -1, 1, 0);
    var objX = (px + 1) / 2 * 100;
    var objY = (py + 1) / 2 * 100;
    var left = 50 * (1 - z) * (1 + px);
    var top  = 50 * (1 - z) * (1 + py);
    bg.style.width  = (100 * z) + '%';
    bg.style.height = (100 * z) + '%';
    bg.style.left   = left + '%';
    bg.style.top    = top  + '%';
    bg.style.right  = 'auto';
    bg.style.bottom = 'auto';
    bg.style.objectPosition = objX + '% ' + objY + '%';
    window.__framingApplied = { zoom:z, panX:px, panY:py, objX:objX, objY:objY, left:left, top:top };
  }
  window.__setWallpaperFraming = applyFraming;
  applyFraming(window.__wallpaperFraming);
})();

(function () {
  "use strict";
  var video = document.getElementById("bg");
  if (!video) return;
  function tryPlay() {
    video.muted = true;
    video.defaultMuted = true;
    video.playsInline = true;
    var p = video.play();
    if (p && typeof p.catch === "function") { p.catch(function () {}); }
  }
  video.addEventListener("canplay", tryPlay);
  video.addEventListener("loadeddata", tryPlay);
  video.addEventListener("ended", tryPlay);
  tryPlay();
})();

(function () {
  var _moodApplied = false;
  var MOOD_RE = /^brightness\(\S+\)\s+saturate\(\S+\)\s+contrast\(\S+\)\s+hue-rotate\(\S+\)\s+sepia\(\S+\)$/;

  function parseMoodNums(f) {
    var bm = /brightness\(([\d.]+)\)/.exec(f);
    var sm = /saturate\(([\d.]+)\)/.exec(f);
    var cm = /contrast\(([\d.]+)\)/.exec(f);
    var hm = /hue-rotate\((-?[\d.]+)deg\)/.exec(f);
    var em = /sepia\(([\d.]+)\)/.exec(f);
    return {
      B:  bm ? parseFloat(bm[1]) : NaN,
      S:  sm ? parseFloat(sm[1]) : NaN,
      C:  cm ? parseFloat(cm[1]) : NaN,
      H:  hm ? parseFloat(hm[1]) : NaN,
      Se: em ? parseFloat(em[1]) : NaN
    };
  }

  function applyMood(m) {
    if (!m || typeof m.filter !== 'string') return;
    var f = m.filter.trim();
    if (!MOOD_RE.test(f)) return;
    var bg = document.getElementById('bg');
    if (!bg) return;
    if (!_moodApplied) {
      _moodApplied = true;
      bg.style.transition = 'none';
      bg.style.filter = f;
      if (!window.__moodHookMode) {
        setTimeout(function () { bg.style.transition = ''; }, 50);
      }
    } else {
      bg.style.filter = f;
    }
    window.__moodApplied = parseMoodNums(f);
  }

  window.__setWallpaperMood = applyMood;
  applyMood(window.__wallpaperMood);
})();

(function () {
  var canvas = document.getElementById("overlay");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");
  if (!ctx) return;

  var currentEffect = null;
  var rafId = null;
  var lastTs = null;
  var running = false;

  window.__overlayStats = { sized: { w: 0, h: 0, dpr: window.devicePixelRatio || 1 }, running: false, frames: 0, hasEffect: false };

  function backingSize(stageW, stageH, d) {
    if (!isFinite(stageW) || !isFinite(stageH) || !isFinite(d)) return null;
    if (stageW <= 0 || stageH <= 0 || d <= 0) return null;
    var w = Math.min(Math.round(stageW * d), 16384);
    var h = Math.min(Math.round(stageH * d), 16384);
    return { w: w, h: h };
  }

  function resizeBacking(stageW, stageH) {
    var d = window.devicePixelRatio || 1;
    var bs = backingSize(stageW, stageH, d);
    if (!bs) return;
    canvas.width = bs.w;
    canvas.height = bs.h;
    canvas.style.width = "100%";
    canvas.style.height = "100%";
    window.__overlayStats.sized = { w: bs.w, h: bs.h, dpr: d };
    if (currentEffect && typeof currentEffect.resize === "function") {
      currentEffect.resize(bs.w, bs.h, d);
    }
  }

  // Initial sizing: prefer window.__wallpaper if valid, else fall back to stage bounds.
  var initW = 0, initH = 0;
  var wp = window.__wallpaper;
  if (wp && isFinite(wp.stageW) && isFinite(wp.stageH) && wp.stageW > 0 && wp.stageH > 0) {
    initW = wp.stageW;
    initH = wp.stageH;
  } else {
    var stageEl = document.getElementById("stage");
    if (stageEl) {
      var r = stageEl.getBoundingClientRect();
      if (isFinite(r.width) && isFinite(r.height) && r.width > 0 && r.height > 0) {
        initW = r.width;
        initH = r.height;
      }
    }
  }
  if (initW > 0 && initH > 0) { resizeBacking(initW, initH); }

  // Wrap __applyWallpaperGeometry so geometry updates also resize the backing store.
  var _origGeo = window.__applyWallpaperGeometry;
  window.__applyWallpaperGeometry = function (g) {
    if (typeof _origGeo === "function") { _origGeo(g); }
    if (g && isFinite(g.stageW) && isFinite(g.stageH) && g.stageW > 0 && g.stageH > 0) {
      resizeBacking(g.stageW, g.stageH);
      // Keep window.__wallpaper stageW/stageH in sync.
      if (window.__wallpaper) {
        window.__wallpaper.stageW = g.stageW;
        window.__wallpaper.stageH = g.stageH;
      }
    }
  };

  function loop(ts) {
    if (!running) return;
    rafId = requestAnimationFrame(loop);
    if (!currentEffect) return;
    var dt = lastTs === null ? 0 : Math.min(ts - lastTs, 100);
    lastTs = ts;
    var w = canvas.width;
    var h = canvas.height;
    if (!currentEffect.manualClear) { ctx.clearRect(0, 0, w, h); }
    currentEffect.frame(ctx, w, h, ts, dt);
    window.__overlayStats.frames += 1;
  }

  function start() {
    if (running) return;
    running = true;
    lastTs = null;
    window.__overlayStats.running = true;
    rafId = requestAnimationFrame(loop);
  }

  function stop() {
    running = false;
    window.__overlayStats.running = false;
    if (rafId !== null) { cancelAnimationFrame(rafId); rafId = null; }
    lastTs = null;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
  }

  function register(effectOrFn) {
    var effect = typeof effectOrFn === "function" ? { frame: effectOrFn } : effectOrFn;
    if (currentEffect && typeof currentEffect.destroy === "function") { currentEffect.destroy(); }
    currentEffect = effect;
    window.__overlayStats.hasEffect = true;
    window.__overlayStats.frames = 0;
    var bs = window.__overlayStats.sized;
    if (typeof effect.init === "function") { effect.init(ctx, bs.w, bs.h, window.__overlayStats.sized.dpr); }
  }

  function unregister() {
    stop();
    if (currentEffect && typeof currentEffect.destroy === "function") { currentEffect.destroy(); }
    currentEffect = null;
    window.__overlayStats.hasEffect = false;
  }

  function setEnabled(bool) {
    if (bool) { start(); } else { stop(); }
  }

  window.__overlay = { register: register, unregister: unregister, clear: unregister, setEnabled: setEnabled, start: start, stop: stop };

  // Test mode: register a minimal effect and start the loop.
  if (window.__overlayTest === true) {
    register({
      frame: function (c, w, h, tMs, dtMs) {
        c.fillStyle = "rgba(255,0,128,0.5)";
        c.fillRect(4, 4, 8, 8);
        // Sample backing pixels once after first draw to verify transparent compositing.
        // Empty region (1,1) must be alpha=0 (clearRect kept it transparent).
        // Marker region (8,8) must be alpha>0 (fillRect drew there).
        if (!window.__overlayStats._pixelSampled) {
          window.__overlayStats._pixelSampled = true;
          try {
            window.__overlayStats.emptyAlpha = c.getImageData(1, 1, 1, 1).data[3];
            window.__overlayStats.markerAlpha = c.getImageData(8, 8, 1, 1).data[3];
          } catch (e) {}
        }
      }
    });
    start();
    // Fallback for environments where rAF is throttled (accessory-policy apps on macOS suppress
    // vsync callbacks for WKWebViews). After 400ms, if rAF has not fired even once, drive frames
    // via setInterval so the gate can verify the drawing mechanism regardless of rAF availability.
    var _rafFired = false;
    requestAnimationFrame(function () { _rafFired = true; });
    setTimeout(function () {
      if (_rafFired || !running || !currentEffect) return;
      var _iv = setInterval(function () {
        if (!running || window.__overlayStats.frames >= 3) { clearInterval(_iv); return; }
        var now = performance.now();
        var dt = lastTs === null ? 0 : Math.min(now - lastTs, 100);
        lastTs = now;
        var cw = canvas.width, ch = canvas.height;
        if (!currentEffect.manualClear) { ctx.clearRect(0, 0, cw, ch); }
        currentEffect.frame(ctx, cw, ch, now, dt);
        window.__overlayStats.frames += 1;
      }, 200);
    }, 400);
  }
})();

window.__setWallpaperVideo = function(src) {
  var v = document.getElementById("bg");
  if (!v) return;
  while (v.firstChild) { v.removeChild(v.firstChild); }
  v.removeAttribute("src");
  v.src = src;
  window.__lastVideoApplied = { src: '', durationMs: 0 };
  v.load();
  v.addEventListener('loadedmetadata', function onMeta() {
    v.removeEventListener('loadedmetadata', onMeta);
    window.__lastVideoApplied = { src: v.currentSrc, durationMs: Math.round((v.duration||0)*1000) };
  });
  v.muted = true;
  var p = v.play();
  if (p && p.catch) { p.catch(function(){}); }
};
