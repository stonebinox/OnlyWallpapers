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

  var effects = {};
  var effectOrder = [];
  var rafId = null;
  var lastTs = null;
  var running = false;

  window.__overlayStats = { sized: { w: 0, h: 0, dpr: window.devicePixelRatio || 1 }, running: false, frames: 0, hasEffect: false, effects: { count: 0, names: [] }, emptyAlpha: null, markerAlpha: null };

  function updateEffectStats() {
    var names = effectOrder.slice();
    window.__overlayStats.hasEffect = names.length > 0;
    window.__overlayStats.effects = { count: names.length, names: names };
  }

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
    for (var i = 0; i < effectOrder.length; i++) {
      var e = effects[effectOrder[i]];
      if (typeof e.resize === "function") { e.resize(bs.w, bs.h, d); }
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
    var dt = lastTs === null ? 0 : Math.min(ts - lastTs, 100);
    lastTs = ts;
    var w = canvas.width, h = canvas.height;
    ctx.clearRect(0, 0, w, h);
    for (var i = 0; i < effectOrder.length; i++) {
      effects[effectOrder[i]].frame(ctx, w, h, ts, dt);
    }
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

  function register(name, effectOrFn) {
    var effect = typeof effectOrFn === "function" ? { frame: effectOrFn } : effectOrFn;
    if (effects[name]) {
      if (typeof effects[name].destroy === "function") { effects[name].destroy(); }
      effects[name] = effect;
    } else {
      effectOrder.push(name);
      effects[name] = effect;
    }
    var bs = window.__overlayStats.sized;
    if (typeof effect.init === "function") { effect.init(ctx, bs.w, bs.h, bs.dpr); }
    updateEffectStats();
  }

  function unregister(name) {
    if (!effects[name]) return;
    if (typeof effects[name].destroy === "function") { effects[name].destroy(); }
    delete effects[name];
    var idx = effectOrder.indexOf(name);
    if (idx >= 0) { effectOrder.splice(idx, 1); }
    updateEffectStats();
    if (effectOrder.length === 0) { stop(); }
  }

  function setEnabled(bool) {
    if (bool) { start(); } else { stop(); }
  }

  window.__overlay = { register: register, unregister: unregister, setEnabled: setEnabled, start: start, stop: stop };

  // Test mode: register a minimal effect and start the loop.
  if (window.__overlayTest === true) {
    register('__test', {
      frame: function (c, w, h, tMs, dtMs) {
        c.fillStyle = "rgba(255,0,128,0.5)";
        c.fillRect(4, 4, 8, 8);
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
  }

  // rAF fallback for any test mode: if rAF is throttled, drive frames via setInterval.
  var _isTestMode = window.__overlayTest === true || window.__l9wTest === true || window.__wgtTest === true;
  if (_isTestMode) {
    var _rafFired = false;
    requestAnimationFrame(function() { _rafFired = true; });
    setTimeout(function() {
      if (_rafFired || !running || effectOrder.length === 0) return;
      var _iv = setInterval(function() {
        if (!running || effectOrder.length === 0 || window.__overlayStats.frames >= 3) {
          clearInterval(_iv); return;
        }
        var now = performance.now();
        var dt2 = lastTs === null ? 0 : Math.min(now - lastTs, 100);
        lastTs = now;
        var cw = canvas.width, ch = canvas.height;
        ctx.clearRect(0, 0, cw, ch);
        for (var i2 = 0; i2 < effectOrder.length; i2++) {
          effects[effectOrder[i2]].frame(ctx, cw, ch, now, dt2);
        }
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

(function () {
  "use strict";

  var FLICKER_MIN        = 2;
  var FLICKER_MAX        = 4;
  var FLASH_RISE_MS      = 20;
  var FLASH_DECAY_MS     = 120;
  var PEAK_ALPHA_MIN     = 0.25;
  var PEAK_ALPHA_MAX     = 0.85;
  var GLOW_RADIUS_FRAC   = 0.38;
  var VEIL_ALPHA         = 0.12;
  var FLASH_COLOR        = [205, 225, 255];
  var INTER_FLICKER_MIN  = 40;
  var INTER_FLICKER_MAX  = 110;
  var PROD_INTERVAL_MIN  = 15000;
  var PROD_INTERVAL_MAX  = 60000;
  var TEST_INTERVAL_MIN  = 2000;
  var TEST_INTERVAL_MAX  = 4000;

  function rnd(lo, hi) { return lo + Math.random() * (hi - lo); }
  function rndInt(lo, hi) { return Math.floor(rnd(lo, hi + 1)); }

  var R = FLASH_COLOR[0];
  var G = FLASH_COLOR[1];
  var B = FLASH_COLOR[2];

  var _wgtStats = null;

  var _phase        = 'idle';
  var _nextBurstAt  = 0;
  var _nextFlickerAt = 0;
  var _decayStart   = 0;
  var _decayEnd     = 0;
  var _flickersLeft = 0;
  var _ox           = 0;
  var _oy           = 0;
  var _peakAlpha    = 0;
  var _riseEnd      = 0;
  var _k            = 3.5 / FLASH_DECAY_MS;

  function scheduleBurst(ts) {
    _phase = 'idle';
    var iMin = (window.__wgtTest === true) ? TEST_INTERVAL_MIN : PROD_INTERVAL_MIN;
    var iMax = (window.__wgtTest === true) ? TEST_INTERVAL_MAX : PROD_INTERVAL_MAX;
    _nextBurstAt = ts + rnd(iMin, iMax);
  }

  function startBurst(w, h, ts) {
    _ox           = rnd(0, w);
    _oy           = rnd(0, h * 0.4);
    _peakAlpha    = rnd(PEAK_ALPHA_MIN, PEAK_ALPHA_MAX);
    _flickersLeft = rndInt(FLICKER_MIN, FLICKER_MAX);
    startFlicker(ts);
  }

  function startFlicker(ts) {
    _phase    = 'rise';
    _riseEnd  = ts + FLASH_RISE_MS;
    _decayStart = _riseEnd;
    _decayEnd   = _decayStart + FLASH_DECAY_MS;
  }

  function drawFlash(ctx, w, h, a) {
    ctx.globalCompositeOperation = 'lighter';

    var primaryRadius = GLOW_RADIUS_FRAC * w;
    var grad = ctx.createRadialGradient(_ox, _oy, 0, _ox, _oy, primaryRadius);
    grad.addColorStop(0, 'rgba(' + R + ',' + G + ',' + B + ',' + a + ')');
    grad.addColorStop(1, 'rgba(' + R + ',' + G + ',' + B + ',0)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(_ox, _oy, primaryRadius, 0, Math.PI * 2);
    ctx.fill();

    var ox2 = _ox - 0.07 * w;
    var oy2 = _oy + 0.04 * h;
    var r2  = 0.55 * primaryRadius;
    var a2  = a * 0.6;
    var grad2 = ctx.createRadialGradient(ox2, oy2, 0, ox2, oy2, r2);
    grad2.addColorStop(0, 'rgba(' + R + ',' + G + ',' + B + ',' + a2 + ')');
    grad2.addColorStop(1, 'rgba(' + R + ',' + G + ',' + B + ',0)');
    ctx.fillStyle = grad2;
    ctx.beginPath();
    ctx.arc(ox2, oy2, r2, 0, Math.PI * 2);
    ctx.fill();

    var veilA = VEIL_ALPHA * a / PEAK_ALPHA_MAX;
    ctx.fillStyle = 'rgba(' + R + ',' + G + ',' + B + ',' + veilA + ')';
    ctx.fillRect(0, 0, w, h);

    ctx.globalCompositeOperation = 'source-over';
    if (!window.__wgtStats) window.__wgtStats = { maxRenderedAlpha: 0, maxAlpha: 0, idleAlpha: 0, postFlashIdleAlpha: -1 };
    _wgtStats = window.__wgtStats;
    var drawnA = Math.round(a * 255);
    if (drawnA > (_wgtStats.maxAlpha || 0)) { _wgtStats.maxAlpha = drawnA; }
    if (window.__wgtTest === true) {
      try {
        var midX = Math.floor(w / 2);
        var midY = Math.floor(h / 4);
        var px = ctx.getImageData(midX, midY, 1, 1).data[3];
        if (px > (_wgtStats.maxRenderedAlpha || 0)) { _wgtStats.maxRenderedAlpha = px; }
      } catch (e) {}
    }
  }

  function frame(ctx, w, h, ts) {
    if (_phase === 'idle') {
      if (!window.__wgtStats) window.__wgtStats = { maxRenderedAlpha: 0, maxAlpha: 0, idleAlpha: 0, postFlashIdleAlpha: -1 };
      _wgtStats = window.__wgtStats;
      if (!_wgtStats._idleSampled) {
        try {
          _wgtStats.idleAlpha = ctx.getImageData(0, 0, 1, 1).data[3];
          _wgtStats._idleSampled = true;
        } catch (e) {}
      }
      if ((_wgtStats.maxRenderedAlpha || 0) > 0 && !_wgtStats._postFlashIdleSampled) {
        try {
          _wgtStats.postFlashIdleAlpha = ctx.getImageData(0, 0, 1, 1).data[3];
          _wgtStats._postFlashIdleSampled = true;
        } catch (e) {}
      }
      if (ts >= _nextBurstAt) { startBurst(w, h, ts); }
      return;
    }

    if (_phase === 'gap') {
      if (ts >= _nextFlickerAt) {
        startFlicker(ts);
      }
      return;
    }

    if (_phase === 'rise') {
      var risePhase = Math.min((ts - (_riseEnd - FLASH_RISE_MS)) / FLASH_RISE_MS, 1);
      var a = _peakAlpha * risePhase;
      drawFlash(ctx, w, h, a);
      if (ts >= _riseEnd) {
        _phase = 'decay';
      }
      return;
    }

    if (_phase === 'decay') {
      if (ts >= _decayEnd) {
        _flickersLeft -= 1;
        if (!window.__wgtStats) window.__wgtStats = { maxRenderedAlpha: 0, maxAlpha: 0, idleAlpha: 0, postFlashIdleAlpha: -1 };
        _wgtStats = window.__wgtStats;
        if ((_wgtStats.maxRenderedAlpha || 0) > 0 && !_wgtStats._postFlashIdleSampled) {
          _wgtStats.postFlashIdleAlpha = 0;
          _wgtStats._postFlashIdleSampled = true;
        }
        if (_flickersLeft <= 0) {
          scheduleBurst(ts);
        } else {
          _phase         = 'gap';
          _nextFlickerAt = ts + rnd(INTER_FLICKER_MIN, INTER_FLICKER_MAX);
        }
        return;
      }
      var decayPhase = ts - _decayStart;
      var ad = _peakAlpha * Math.exp(-_k * decayPhase);
      drawFlash(ctx, w, h, ad);
      return;
    }
  }

  function init(ctx, w, h, dpr) {
    scheduleBurst(performance.now());
    if (window.__wgtTest === true) {
      _nextBurstAt = performance.now() + 200;
    }
  }

  function resize(w, h, dpr) {}

  var lightningEffect = {
    frame: frame,
    init: init,
    resize: resize
  };

  window.__wgtFlashAlpha = function(elapsedMs, peak) {
    if (elapsedMs < 0) return 0;
    if (elapsedMs < FLASH_RISE_MS) return peak * (elapsedMs / FLASH_RISE_MS);
    var decayElapsed = elapsedMs - FLASH_RISE_MS;
    if (decayElapsed >= FLASH_DECAY_MS) return 0;
    return peak * Math.exp(-_k * decayElapsed);
  };

  var _stormRegistered = false;
  var _reducedMotion = false;
  if (typeof window.matchMedia === 'function') {
    var _rmMq = window.matchMedia('(prefers-reduced-motion: reduce)');
    _reducedMotion = _rmMq.matches;
    if (typeof _rmMq.addEventListener === 'function') {
      _rmMq.addEventListener('change', function(e) {
        _reducedMotion = e.matches;
        applyStorm(window.__wallpaperStorm === true);
      });
    }
  }

  function applyStorm(active) {
    var rm = _reducedMotion || (window.__wgtReducedMotion === true);
    if (rm) {
      if (_stormRegistered) { window.__overlay.unregister('lightning'); _stormRegistered = false; }
      return;
    }
    var effectiveActive = active || (window.__wgtTest === true);
    if (effectiveActive && !_stormRegistered) {
      window.__overlay.register('lightning', lightningEffect);
      window.__overlay.start();
      _stormRegistered = true;
    } else if (!effectiveActive && _stormRegistered) {
      window.__overlay.unregister('lightning');
      _stormRegistered = false;
    }
  }

  window.__setWallpaperStorm = applyStorm;
  applyStorm(window.__wallpaperStorm === true);
})();

(function () {
  "use strict";

  // ============================================================
  // RAIN EFFECT (ow-l9w) -- all visual knobs in one place
  // ============================================================
  // Per-layer: [far, mid, near]
  var LAYERS = [
    { COUNT_PER_MP: 60, COUNT_MAX: 1000, LEN_MIN: 14, LEN_MAX: 30,  SPEED_MIN: 280, SPEED_MAX: 560,  THICK_MIN: 0.4, THICK_MAX: 0.9, ALPHA_MIN: 0.07, ALPHA_MAX: 0.20, WIND_SCALE: 0.50 },
    { COUNT_PER_MP: 22, COUNT_MAX:  420, LEN_MIN: 28, LEN_MAX: 58,  SPEED_MIN: 560, SPEED_MAX: 980,  THICK_MIN: 0.7, THICK_MAX: 1.5, ALPHA_MIN: 0.13, ALPHA_MAX: 0.34, WIND_SCALE: 0.78 },
    { COUNT_PER_MP:  7, COUNT_MAX:  140, LEN_MIN: 55, LEN_MAX: 110, SPEED_MIN: 980, SPEED_MAX: 1650, THICK_MIN: 1.1, THICK_MAX: 2.5, ALPHA_MIN: 0.23, ALPHA_MAX: 0.54, WIND_SCALE: 1.00 },
  ];

  var GUST_AMPLITUDE = 0.10;  // peak-to-zero modulation added on top of wind
  var GUST_PERIOD    = 8800;  // ms for one full gust cycle
  var MAX_SLANT_DEG  = 65;    // cap slant angle from vertical (degrees)

  var COLOR      = [190, 210, 235];
  var BLEND_MODE = "screen";

  var MIST_ALPHA  = 0.038;
  var MIST_HEIGHT = 0.07;
  // ============================================================

  function rnd(lo, hi) { return lo + Math.random() * (hi - lo); }

  // Current rain state (driven by __setWallpaperRain)
  var _active      = false;
  var _intensity   = 0.0;
  var _windStr     = 0.0;   // 0..1
  var _windDir     = 270.0; // degrees FROM

  var _drops  = null;
  var _cw     = 0;
  var _ch     = 0;

  window.__l9wStats = { slantSign: 0, frames: 0, maxRenderedAlpha: 0, lastDrawnDx: 0 };

  function makeDrop(lc, w, h, scatter) {
    return {
      x:     rnd(scatter ? 0 : -w * 0.1, w * (scatter ? 1.0 : 1.1)),
      y:     scatter ? rnd(0, h) : rnd(-h * 0.25, -2),
      speed: rnd(lc.SPEED_MIN, lc.SPEED_MAX),
      len:   rnd(lc.LEN_MIN,   lc.LEN_MAX),
      thick: rnd(lc.THICK_MIN, lc.THICK_MAX),
      alpha: rnd(lc.ALPHA_MIN, lc.ALPHA_MAX),
    };
  }

  function buildDrops(w, h) {
    var intensityScale = 0.3 + 0.7 * _intensity;
    var mpx = (w * h) / 1e6;
    _drops = LAYERS.map(function (lc) {
      var n = Math.min(Math.max(10, Math.round(lc.COUNT_PER_MP * mpx * intensityScale)), lc.COUNT_MAX);
      var arr = [];
      for (var i = 0; i < n; i++) { arr.push(makeDrop(lc, w, h, true)); }
      return arr;
    });
    _cw = w;
    _ch = h;
  }

  function frame(ctx, w, h, tMs, dtMs) {
    if (!_drops || _cw !== w || _ch !== h) { buildDrops(w, h); }

    var dt = Math.min(dtMs, 50) / 1000;

    // Base horizontal wind direction from wind state
    // windDir is degrees the wind comes FROM; horizontal component = -sin(radians) * windStr
    var windRad = _windDir * Math.PI / 180;
    var horizDir = -Math.sin(windRad) * _windStr;

    // Max slant: cap at 65 deg from vertical
    var maxTan = Math.tan(MAX_SLANT_DEG * Math.PI / 180);
    if (horizDir > maxTan) { horizDir = maxTan; }
    if (horizDir < -maxTan) { horizDir = -maxTan; }

    // Sinusoidal gust modulation on top of base wind
    var gustPhase = (tMs % GUST_PERIOD) / GUST_PERIOD * (Math.PI * 2);
    var gustMod   = GUST_AMPLITUDE * Math.sin(gustPhase);
    var windFrac  = horizDir + gustMod;

    // Update slant sign for gate readback (positive=right, negative=left)
    window.__l9wStats.slantSign = horizDir >= 0.0001 ? 1 : (horizDir <= -0.0001 ? -1 : 0);
    window.__l9wStats.frames += 1;

    var Rc = COLOR[0], Gc = COLOR[1], Bc = COLOR[2];

    ctx.save();
    ctx.globalCompositeOperation = BLEND_MODE;
    ctx.lineCap = "round";

    var _dxRecorded = false;

    for (var li = 0; li < LAYERS.length; li++) {
      var lc        = LAYERS[li];
      var layerArr  = _drops[li];
      var wScale    = lc.WIND_SCALE;
      var speedSpan = lc.SPEED_MAX - lc.SPEED_MIN + 1;

      for (var di = 0; di < layerArr.length; di++) {
        var d = layerArr[di];

        var vy = d.speed * dt;
        var vx = d.speed * windFrac * wScale * dt;

        d.x += vx;
        d.y += vy;

        if (d.y > h + d.len + 6) {
          var fr = makeDrop(lc, w, h, false);
          d.x = fr.x; d.y = fr.y;
          d.speed = fr.speed; d.len = fr.len;
          d.thick = fr.thick; d.alpha = fr.alpha;
          continue;
        }

        var speedRatio = (d.speed - lc.SPEED_MIN) / speedSpan;
        var streakLen  = d.len * (0.38 + 0.62 * speedRatio);
        var norm = Math.sqrt(vx * vx + vy * vy);
        var tx, ty;
        if (norm < 0.001) {
          tx = d.x; ty = d.y - streakLen;
        } else {
          tx = d.x - (vx / norm) * streakLen;
          ty = d.y - (vy / norm) * streakLen;
        }

        if (!_dxRecorded && li === LAYERS.length - 1) {
          window.__l9wStats.lastDrawnDx = d.x - tx;
          _dxRecorded = true;
        }

        var grad = ctx.createLinearGradient(tx, ty, d.x, d.y);
        grad.addColorStop(0,    "rgba(" + Rc + "," + Gc + "," + Bc + ",0)");
        grad.addColorStop(0.45, "rgba(" + Rc + "," + Gc + "," + Bc + "," + (d.alpha * 0.45) + ")");
        grad.addColorStop(1,    "rgba(" + Rc + "," + Gc + "," + Bc + "," + d.alpha + ")");

        ctx.lineWidth   = d.thick;
        ctx.strokeStyle = grad;
        ctx.beginPath();
        ctx.moveTo(tx, ty);
        ctx.lineTo(d.x, d.y);
        ctx.stroke();
      }
    }

    if (MIST_ALPHA > 0) {
      var mh = h * MIST_HEIGHT;
      var mg = ctx.createLinearGradient(0, h - mh, 0, h);
      mg.addColorStop(0, "rgba(" + Rc + "," + Gc + "," + Bc + ",0)");
      mg.addColorStop(1, "rgba(" + Rc + "," + Gc + "," + Bc + "," + MIST_ALPHA + ")");
      ctx.globalCompositeOperation = "source-over";
      ctx.fillStyle = mg;
      ctx.fillRect(0, h - mh, w, mh);
    }

    ctx.restore();

    if (window.__l9wTest === true) {
      try {
        var stats = window.__l9wStats;
        if (typeof stats.maxRenderedAlpha !== 'number') { stats.maxRenderedAlpha = 0; }
        var stripY = Math.floor(h * 0.40);
        var stripH = 4;
        var stripW = Math.max(1, w);
        var stripData = ctx.getImageData(0, stripY, stripW, stripH).data;
        for (var pi = 3; pi < stripData.length; pi += 4) {
          if (stripData[pi] > stats.maxRenderedAlpha) { stats.maxRenderedAlpha = stripData[pi]; }
        }
        if (!stats._emptyRegionSampled) {
          stats._emptyRegionSampled = true;
          stats.emptyRegionAlpha = ctx.getImageData(0, 0, 1, 1).data[3];
        }
      } catch(e) {}
    }
  }

  function init(ctx, w, h) {
    window.__l9wStats.frames = 0;
    buildDrops(w, h);
  }
  function resize(w, h) { buildDrops(w, h); }

  var rainEffect = { frame: frame, init: init, resize: resize };

  window.__l9wRainEffect = rainEffect;

  // Reduced-motion state
  var _reducedMotion = false;
  if (typeof window.matchMedia === 'function') {
    var _rmMq = window.matchMedia('(prefers-reduced-motion: reduce)');
    _reducedMotion = _rmMq.matches;
    if (typeof _rmMq.addEventListener === 'function') {
      _rmMq.addEventListener('change', function (e) {
        _reducedMotion = e.matches;
        applyRain(_active, _intensity, _windStr, _windDir);
      });
    }
  }

  var _rainRegistered = false;

  function applyRain(active, intensity, windStr, windDir) {
    var rm = _reducedMotion || (window.__l9wReducedMotion === true);
    _active    = active;
    _intensity = intensity;
    _windStr   = windStr;
    _windDir   = windDir;
    if (rm) {
      if (_rainRegistered) { window.__overlay.unregister('rain'); _rainRegistered = false; }
      return;
    }
    var effectiveActive = active || (window.__l9wTest === true);
    if (effectiveActive && !_rainRegistered) {
      window.__l9wStats.frames = 0;
      _drops = null; // force rebuild with new intensity
      window.__overlay.register('rain', rainEffect);
      window.__overlay.start();
      _rainRegistered = true;
    } else if (effectiveActive && _rainRegistered) {
      // Update params in-place; rebuild drops on next frame due to intensity change
      _drops = null;
    } else if (!effectiveActive && _rainRegistered) {
      window.__overlay.unregister('rain');
      _rainRegistered = false;
    }
  }

  window.__setWallpaperRain = function (s) {
    if (!s) return;
    var active    = s.active === true;
    var intensity = typeof s.intensity    === 'number' ? Math.min(Math.max(s.intensity, 0), 1) : 0;
    var windStr   = typeof s.windStrength === 'number' ? Math.min(Math.max(s.windStrength, 0), 1) : 0;
    var windDir   = typeof s.windDir      === 'number' ? s.windDir : 270;
    applyRain(active, intensity, windStr, windDir);
  };

  // Apply initial state from document-start injection or default
  var _initRain = window.__wallpaperRain;
  window.__setWallpaperRain(_initRain || { active: false, intensity: 0, windStrength: 0, windDir: 270 });
})();
