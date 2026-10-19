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
    // Assigning width reallocates and clears the whole backing store (100 MB on a 3 display
    // stage) and stalls this page for seconds. A geometry update that only moves the slice
    // offset leaves the size unchanged, so skip the reallocation.
    if (canvas.width === bs.w && canvas.height === bs.h) {
      window.__overlayStats.sized = { w: bs.w, h: bs.h, dpr: d };
      return;
    }
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

  function drawFrame(ts) {
    var dt = lastTs === null ? 0 : Math.min(ts - lastTs, 100);
    lastTs = ts;
    var w = canvas.width, h = canvas.height;
    ctx.clearRect(0, 0, w, h);
    for (var i = 0; i < effectOrder.length; i++) {
      effects[effectOrder[i]].frame(ctx, w, h, ts, dt);
    }
    window.__overlayStats.frames += 1;
  }

  function loop(ts) {
    if (!running) return;
    rafId = requestAnimationFrame(loop);
    drawFrame(ts);
  }

  // OW_SYNC_TEST: occluded windows get no rAF and only 1 Hz timers, so the native test sampler
  // drives frames through this hook. It runs the same frame code as rAF does.
  if (window.__syncTest === true || window.__wgtTest === true) {
    window.__syncOverlayFrame = function () {
      if (!running || effectOrder.length === 0) return;
      drawFrame(performance.now());
    };
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
        // The lightning schedule is a pure function of the wall clock (a burst lands anywhere in its
        // slot), so wgt test mode keeps this fallback running to catch a flash on a throttled window.
        if (!running || effectOrder.length === 0 || (window.__overlayStats.frames >= 3 && window.__wgtTest !== true)) {
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

(function () {
  "use strict";
  var video = document.getElementById("bg");
  if (!video) return;

  // ow-blz.5: the sync controller is the ONLY caller of play() and the only author of the wrap.
  // The <video> has no autoplay and no loop. Target time is a pure function of the wall clock
  // and the native session tuple (epochMs, sourceRev, durationSec, seed).
  var TICK_MS = 250;
  var RATE_SPAN = 0.01;
  var RATE_GAIN = 1.5;
  var FRAME_DEFAULT = 1 / 30;
  var LATENCY_DEFAULT = 0.04;
  var PRES_FRESH_MS = 600;
  // Nudge threshold: min(half a frame, 5 ms). A half-frame deadband would let two windows each sit
  // a half frame off in opposite directions, i.e. one whole frame apart, which is the entire budget.
  var NUDGE_DEADBAND_MAX = 0.005;
  var SETTLE_MS = 400;
  // Re-seek after a landing that is more than this many frames off (plan: 2 frames is the hard
  // limit; a tighter landing keeps two windows inside one frame of each other across seams).
  var RECHECK_THRESH = 0.45;

  var sess = null;
  var gen = 0;
  var joined = false;
  var biasMs = 0;
  var latency = LATENCY_DEFAULT;
  var frameDur = FRAME_DEFAULT;
  var lastSeekWall = 0;
  var seekGen = -1;
  var seekStartWall = 0;
  var recheckTimer = null;
  var recheckBudget = 0;
  var wrapTimer = null;
  var tickTimer = null;
  var stats = { seeks: 0, nudges: 0, joins: 0 };
  var pres = { mediaTime: NaN, errPres: NaN, wall: 0, wallAtDisplay: 0, count: 0 };
  var wrapHintMs = 0;
  var rvfcArmed = false;
  var desyncAppliedErr = null;
  var desyncTrace = null;
  var desyncHookWall = 0;

  function sameSession(a, b) {
    return !!a && !!b && a.epochMs === b.epochMs && a.sourceRev === b.sourceRev &&
      a.durationSec === b.durationSec && a.seed === b.seed;
  }

  function dur() {
    // Only the shared session duration: never the per-element duration. If the native probe failed
    // (durationSec 0) the controller adopts ONE reported duration and broadcasts it to every view.
    return (sess && sess.durationSec > 0) ? sess.durationSec : 0;
  }

  function targetAt(wallMs) {
    var d = dur();
    if (!sess || !(d > 0)) return NaN;
    var t = ((wallMs - sess.epochMs) / 1000) % d;
    if (t < 0) t += d;
    return t;
  }

  function wrapErr(e, d) {
    if (!(d > 0) || !isFinite(e)) return e;
    e = e % d;
    if (e > d / 2) e -= d;
    if (e < -d / 2) e += d;
    return e;
  }

  // OW_SYNC_TEST: a short ring of media events and play() outcomes, logged with every sample.
  var evRing = [];
  function note(what) {
    if (window.__syncTest !== true) return;
    evRing.push(Math.round(performance.now()) + ":" + what);
    if (evRing.length > 14) { evRing.shift(); }
  }

  function play() {
    video.muted = true;
    video.defaultMuted = true;
    video.playsInline = true;
    var p = video.play();
    if (p && typeof p.catch === "function") { p.catch(function (e) { note("play-rejected:" + (e && e.name)); }); }
  }

  function clearTimers() {
    if (wrapTimer !== null) { clearTimeout(wrapTimer); wrapTimer = null; }
    if (recheckTimer !== null) { clearTimeout(recheckTimer); recheckTimer = null; }
  }

  function setRate(r) {
    r = Math.min(Math.max(r, 1 - RATE_SPAN), 1 + RATE_SPAN);
    if (Math.abs(video.playbackRate - r) > 1e-4) { video.playbackRate = r; }
  }

  // Seek to where the timeline will be once the seek has completed (now + learned latency).
  // wrapHintMs is the wall time of an imminent wrap: never land before it (a timer that fires a
  // few ms early must still seek to the start of the clip, not to its last frame).
  function seekTo(retry) {
    var d = dur();
    if (!(d > 0)) return;
    if (!retry) { recheckBudget = 3; }
    var t0 = Date.now();
    var wallT = t0 + biasMs + latency * 1000;
    if (wrapHintMs && wallT < wrapHintMs) { wallT = wrapHintMs; }
    wrapHintMs = 0;
    var t = targetAt(wallT);
    if (!(t >= 0)) return;
    // A seek lands on the frame at or before the requested time, up to a frame early. Snap to the
    // nearest frame boundary (plus a quarter frame so float noise cannot pick the previous frame).
    var snapped = Math.round(t / frameDur) * frameDur + 0.25 * frameDur;
    if (snapped < d - 0.5 * frameDur) { t = snapped; }
    seekGen = gen;
    seekStartWall = t0;
    lastSeekWall = t0;
    stats.seeks += 1;
    note("seekTo:" + t.toFixed(3));
    setRate(1);
    try { video.currentTime = t; } catch (e) {}
    if (video.ended) {
      // play() on an ended element restarts at 0 and overrides this seek: wait for it to land.
      var myGen = gen;
      video.addEventListener("seeked", function onSeeked() {
        video.removeEventListener("seeked", onSeeked);
        if (myGen === gen) { play(); }
      });
    } else {
      play();
    }
  }

  // Error of what is on screen against the timeline, in seconds (positive = ahead). The presented
  // frame (requestVideoFrameCallback) is the truth: WebKit's currentTime can freeze after an
  // 'ended' while playback continues. currentTime is only the fallback when no fresh presented
  // frame exists (hidden pages deliver presented frames at a few Hz, so freshness is generous).
  function measureErr(now) {
    var d = dur();
    if (isFinite(pres.errPres) && pres.wall >= lastSeekWall + 30 && now - pres.wall <= PRES_FRESH_MS) {
      return wrapErr(pres.errPres - biasMs / 1000, d);
    }
    if (video.seeking || (pres.count > 0 && now - lastSeekWall < 400)) { return NaN; }
    return wrapErr(video.currentTime - targetAt(now + biasMs), d);
  }

  function scheduleWrap() {
    if (wrapTimer !== null) { clearTimeout(wrapTimer); wrapTimer = null; }
    var d = dur();
    if (!sess || !(d > 0)) return;
    var myGen = gen;
    var wall = Date.now() + biasMs;
    var into = (((wall - sess.epochMs) / 1000) % d + d) % d;
    var untilWrapMs = (d - into) * 1000;
    var fireIn = untilWrapMs - latency * 1000;
    if (fireIn < 5) { fireIn += d * 1000; untilWrapMs += d * 1000; }
    var wrapAt = Date.now() + untilWrapMs;
    wrapTimer = setTimeout(function () {
      wrapTimer = null;
      if (myGen !== gen || !joined) return;
      wrapHintMs = wrapAt + biasMs;
      seekTo();
      scheduleWrap();
    }, fireIn);
  }

  function join() {
    if (!sess || video.readyState < 1) return;
    if (!(dur() > 0)) return;
    joined = true;
    stats.joins += 1;
    seekTo();
    scheduleWrap();
    startTick();
  }

  function recheck(myGen) {
    if (myGen !== gen || !joined) return;
    if (video.seeking) {
      recheckTimer = setTimeout(function () { recheck(myGen); }, 100);
      return;
    }
    var err = measureErr(Date.now());
    if (!isFinite(err)) {
      recheckTimer = setTimeout(function () { recheck(myGen); }, 100);
      return;
    }
    // Learn the seek latency: landing ahead (err > 0) means the lead was too long.
    latency = Math.min(Math.max(latency - err * 0.8, 0.01), 0.6);
    // One corrective re-seek when the landing was more than a frame off (the learned latency
    // above makes the second landing much tighter); rate nudges only take 10 ms per second.
    if (Math.abs(err) > RECHECK_THRESH * frameDur && recheckBudget > 0) {
      recheckBudget -= 1;
      seekTo(true);
    }
  }

  function tick() {
    if (!sess || !joined) return;
    if (video.error) return;
    var now = Date.now();
    if (video.ended && !video.seeking && now - lastSeekWall > SETTLE_MS) { seekTo(); return; }
    if (video.paused && !video.seeking && !video.ended) { play(); }
    if (video.seeking || now - lastSeekWall < SETTLE_MS) return;
    var err = measureErr(now);
    if (!isFinite(err)) return;
    var ae = Math.abs(err);
    if (ae > 2 * frameDur) {
      seekTo();
    } else if (ae > Math.min(0.5 * frameDur, NUDGE_DEADBAND_MAX)) {
      stats.nudges += 1;
      setRate(1 - Math.min(Math.max(err * RATE_GAIN, -RATE_SPAN), RATE_SPAN));
    } else {
      setRate(1);
    }
  }

  function startTick() {
    if (tickTimer !== null) return;
    tickTimer = setInterval(tick, TICK_MS);
  }

  // Presented-frame sample: the mediaTime of the frame actually composited, against the target
  // at its expected display time. Used for the join re-check and for the gate; logged per window.
  function armRvfc() {
    if (rvfcArmed || typeof video.requestVideoFrameCallback !== "function") return;
    rvfcArmed = true;
    var cb = function (now, md) {
      var wallNow = Date.now();
      var disp = (md && isFinite(md.expectedDisplayTime)) ? md.expectedDisplayTime : now;
      var wallAtDisplay = wallNow - performance.now() + disp;
      if (isFinite(pres.mediaTime) && md.mediaTime > pres.mediaTime) {
        var delta = md.mediaTime - pres.mediaTime;
        var frames = (isFinite(md.presentedFrames) && isFinite(pres.presentedFrames)) ? md.presentedFrames - pres.presentedFrames : 1;
        var per = frames >= 1 ? delta / frames : delta;
        if (per > 0.004 && per < 0.2) { frameDur = per; }
      }
      pres.presentedFrames = md.presentedFrames;
      pres.mediaTime = md.mediaTime;
      pres.wall = wallNow;
      pres.wallAtDisplay = wallAtDisplay;
      pres.count += 1;
      pres.errPres = wrapErr(md.mediaTime - targetAt(wallAtDisplay), dur());
      if (desyncTrace && wallNow - desyncHookWall <= 1500 && desyncTrace.length < 200) {
        desyncTrace.push({ dt: wallNow - desyncHookWall, errPres: pres.errPres });
      }
      video.requestVideoFrameCallback(cb);
    };
    video.requestVideoFrameCallback(cb);
  }

  function applySession(next) {
    if (!next || sameSession(sess, next)) return false;
    sess = {
      epochMs: next.epochMs, sourceRev: next.sourceRev,
      durationSec: next.durationSec, seed: next.seed
    };
    window.__wallpaperSession = sess;
    gen += 1;
    joined = false;
    clearTimers();
    pres.mediaTime = NaN;
    pres.errPres = NaN;
    if (video.readyState >= 1) { join(); }
    return true;
  }

  ["seeking", "seeked", "ended", "pause", "play", "playing", "waiting", "stalled", "emptied", "abort", "error"].forEach(function (n) {
    video.addEventListener(n, function () { note(n); });
  });
  // Reported to native only (probe-failure path); this window never derives its own duration from it.
  window.__videoMetaDuration = 0;
  video.addEventListener("loadedmetadata", function () {
    window.__videoMetaDuration = (isFinite(video.duration) && video.duration > 0) ? video.duration : 0;
    armRvfc(); join();
  });
  video.addEventListener("playing", function () { if (!joined) join(); });
  video.addEventListener("ended", function () { if (joined && Date.now() - lastSeekWall > 100) { seekTo(); } });
  video.addEventListener("seeked", function () {
    if (seekGen !== gen || !joined) return;
    var measured = (Date.now() - seekStartWall) / 1000;
    if (measured > 0.005 && measured < 1) { latency = 0.5 * latency + 0.5 * measured; }
    if (recheckTimer !== null) { clearTimeout(recheckTimer); }
    var myGen = gen;
    recheckTimer = setTimeout(function () { recheckTimer = null; recheck(myGen); }, 250);
  });
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible" && sess) { join(); }
  });

  window.__applyWallpaperSession = applySession;

  window.__setWallpaperVideo = function (src, next) {
    var v = document.getElementById("bg");
    if (!v) return;
    // Session and source change in this one call so no window plays the new file on the old epoch.
    // Source first: load() resets readyState, so applySession cannot join the outgoing file.
    while (v.firstChild) { v.removeChild(v.firstChild); }
    v.removeAttribute("src");
    v.src = src;
    window.__lastVideoApplied = { src: '', durationMs: 0 };
    window.__videoMetaDuration = 0;
    v.load();
    v.addEventListener('loadedmetadata', function onMeta() {
      v.removeEventListener('loadedmetadata', onMeta);
      window.__lastVideoApplied = { src: v.currentSrc, durationMs: Math.round((v.duration || 0) * 1000) };
    });
    v.muted = true;
    if (next) { applySession(next); } else { gen += 1; joined = false; clearTimers(); }
  };

  window.__syncSample = function () {
    var now = Date.now();
    var d = dur();
    var ct = video.currentTime;
    var presAge = pres.wall ? now - pres.wall : -1;
    return {
      rev: sess ? sess.sourceRev : -1,
      epochMs: sess ? sess.epochMs : 0,
      durationSec: d,
      now: now,
      mediaTime: isFinite(pres.mediaTime) ? pres.mediaTime : null,
      presAgeMs: presAge,
      presWall: pres.wallAtDisplay,
      vis: document.visibilityState,
      currentTime: ct,
      errCur: sess ? wrapErr(ct - targetAt(now), d) : null,
      errPres: isFinite(pres.errPres) ? pres.errPres : null,
      rate: video.playbackRate,
      paused: video.paused,
      seeking: video.seeking,
      ended: video.ended,
      readyState: video.readyState,
      frameDur: frameDur,
      joined: joined,
      seeks: stats.seeks,
      nudges: stats.nudges,
      latency: latency,
      biasMs: biasMs,
      desyncAppliedErr: desyncAppliedErr,
      desyncTrace: (desyncTrace && now - desyncHookWall <= 3000) ? desyncTrace : null,
      sinceSeekMs: lastSeekWall ? now - lastSeekWall : -1,
      ev: evRing
    };
  };

  if (window.__syncTest === true) {
    window.__syncTestDesync = function (ms) {
      var d = dur();
      if (!(d > 0)) return;
      var t = (video.currentTime + ms / 1000) % d;
      if (t < 0) t += d;
      video.currentTime = t;
      // Self-reported error (informational only: the retire routing check reads it).
      desyncAppliedErr = wrapErr(video.currentTime - targetAt(Date.now()), d);
      // The controller can correct the offset within one 250 ms tick, faster than the native 250 ms
      // sampler sees it, and occluded pages get only 1 Hz timers. So every presented frame (the
      // requestVideoFrameCallback below) is recorded for 1.5 s after the hook: the harness then
      // asserts on the presented-frame error, never on the self-report above.
      desyncHookWall = Date.now();
      desyncTrace = [];
    };
    window.__syncTestBias = function (ms) {
      biasMs = ms;
      if (joined) { seekTo(); scheduleWrap(); }
    };
  }

  armRvfc();
  applySession(window.__wallpaperSession);
})();

(function () {
  "use strict";

  // ow-blz.6: lightning is a stateless pure function of (seed, Date.now()). Every window computes
  // the same event record from the shared session seed, so a strike lands on all displays at the
  // same wall-clock instant and at the same point of the union stage. No Math.random and no rAF
  // timestamp on the scheduling or envelope path; rAF only decides when the result is drawn.
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
  // One burst per slot at a hashed offset in [0, OFFSET_SPAN]. Consecutive bursts are then
  // SLOT - OFFSET_SPAN .. SLOT + OFFSET_SPAN apart: production 15 to 60 s, test 2 to 4 s.
  var PROD_SLOT_MS       = 37500;
  var PROD_OFFSET_SPAN   = 22500;
  var TEST_SLOT_MS       = 3000;
  var TEST_OFFSET_SPAN   = 1000;
  var EVENT_LOG_MAX      = 64;

  var R = FLASH_COLOR[0];
  var G = FLASH_COLOR[1];
  var B = FLASH_COLOR[2];

  var _k = 3.5 / FLASH_DECAY_MS;
  var _wgtStats = null;

  function mulberry32(a) {
    return function () {
      a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function slotRng(seed, slot) {
    var s = (Math.imul((seed >>> 0) ^ 0x9E3779B9, 0x85EBCA6B) ^ Math.imul(slot >>> 0, 0xC2B2AE35)) >>> 0;
    var r = mulberry32(s);
    r(); r();
    return r;
  }

  function lerp(lo, hi, u) { return lo + u * (hi - lo); }
  function round2(x) { return Math.round(x * 100) / 100; }
  function round4(x) { return Math.round(x * 10000) / 10000; }

  function slotConfig(test) {
    return test ? { slot: TEST_SLOT_MS, span: TEST_OFFSET_SPAN } : { slot: PROD_SLOT_MS, span: PROD_OFFSET_SPAN };
  }

  // The burst of one slot. Origin is in UNION STAGE POINTS (stageW x stageH), never in pixels.
  function lightningEvent(seed, slotIdx, stageW, stageH, test) {
    var cfg = slotConfig(test);
    var r = slotRng(seed, slotIdx);
    var start = slotIdx * cfg.slot + Math.round(r() * cfg.span);
    var ox = round2(r() * stageW);
    var oy = round2(r() * stageH * 0.4);
    var peak = round4(lerp(PEAK_ALPHA_MIN, PEAK_ALPHA_MAX, r()));
    var n = FLICKER_MIN + Math.floor(r() * (FLICKER_MAX - FLICKER_MIN + 1));
    var flickers = [];
    var t = 0;
    for (var i = 0; i < n; i++) {
      flickers.push(t);
      t += FLASH_RISE_MS + FLASH_DECAY_MS;
      if (i < n - 1) { t += Math.round(lerp(INTER_FLICKER_MIN, INTER_FLICKER_MAX, r())); }
    }
    return { id: slotIdx, start: start, ox: ox, oy: oy, peak: peak, flickers: flickers, end: start + t };
  }

  function flashAlpha(elapsedMs, peak) {
    if (elapsedMs < 0) return 0;
    if (elapsedMs < FLASH_RISE_MS) return peak * (elapsedMs / FLASH_RISE_MS);
    var decayElapsed = elapsedMs - FLASH_RISE_MS;
    if (decayElapsed >= FLASH_DECAY_MS) return 0;
    return peak * Math.exp(-_k * decayElapsed);
  }

  function eventAlpha(ev, nowMs) {
    var el = nowMs - ev.start;
    if (el < 0) return 0;
    for (var i = 0; i < ev.flickers.length; i++) {
      var d = el - ev.flickers[i];
      if (d >= 0 && d < FLASH_RISE_MS + FLASH_DECAY_MS) { return flashAlpha(d, ev.peak); }
    }
    return 0;
  }

  // Pure: same inputs, same output, on every window. A burst always ends before its slot does.
  function lightningAt(seed, nowMs, stageW, stageH, test) {
    var cfg = slotConfig(test);
    var ev = lightningEvent(seed, Math.floor(nowMs / cfg.slot), stageW, stageH, test);
    return { event: ev, alpha: eventAlpha(ev, nowMs) };
  }

  function drawFlash(ctx, w, h, a, ox, oy) {
    ctx.globalCompositeOperation = 'lighter';

    var primaryRadius = GLOW_RADIUS_FRAC * w;
    var grad = ctx.createRadialGradient(ox, oy, 0, ox, oy, primaryRadius);
    grad.addColorStop(0, 'rgba(' + R + ',' + G + ',' + B + ',' + a + ')');
    grad.addColorStop(1, 'rgba(' + R + ',' + G + ',' + B + ',0)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(ox, oy, primaryRadius, 0, Math.PI * 2);
    ctx.fill();

    var ox2 = ox - 0.07 * w;
    var oy2 = oy + 0.04 * h;
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
    ensureStats();
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

  function ensureStats() {
    if (!window.__wgtStats) window.__wgtStats = { maxRenderedAlpha: 0, maxAlpha: 0, idleAlpha: 0, postFlashIdleAlpha: -1 };
    _wgtStats = window.__wgtStats;
  }

  // Event records the window actually drew (OW_SYNC_TEST compares them across windows).
  var _eventLog = [];
  var _eventSeen = {};
  function logEvent(ev, nowMs) {
    if (_eventSeen[ev.id]) return;
    _eventSeen[ev.id] = true;
    _eventLog.push({ event: ev, firstDrawnAt: nowMs });
    if (_eventLog.length > EVENT_LOG_MAX) { _eventLog.shift(); }
  }
  window.__syncEvents = function () { return { events: _eventLog, pixel: window.__wgtLastFlashPixel || null }; };

  function stageDims(w, h) {
    var wp = window.__wallpaper;
    if (wp && isFinite(wp.stageW) && isFinite(wp.stageH) && wp.stageW > 0 && wp.stageH > 0) {
      return { w: wp.stageW, h: wp.stageH };
    }
    var d = (window.__overlayStats && window.__overlayStats.sized && window.__overlayStats.sized.dpr) || window.devicePixelRatio || 1;
    return { w: w / d, h: h / d };
  }

  // OW_SYNC_TEST falsifiability hook: this window computes its schedule `delay` ms late, so its
  // strikes are drawn late while firstDrawnAt still records the real wall clock.
  var _testDelayMs = 0;
  if (window.__syncTest === true) {
    window.__syncTestLightningDelay = function (ms) { _testDelayMs = ms; };
    // Falsifiability hook: this window alone draws ONE extra independent strike, `ms` from now.
    window.__syncTestExtraStrike = function (ms) {
      var t = Date.now() + ms;
      _testExtra = { id: 'extra-' + t, start: t, end: t + 400, ox: 100, oy: 100, peak: 0.6, flickers: [0] };
    };
  }
  var _testExtra = null;

  function frame(ctx, w, h) {
    var now = Date.now();
    var sess = window.__wallpaperSession;
    var seed = (sess && isFinite(sess.seed)) ? sess.seed : 0;
    var sd = stageDims(w, h);
    if (_testExtra && now >= _testExtra.start && now <= _testExtra.end) {
      drawFlash(ctx, w, h, 0.6, _testExtra.ox * (w / sd.w), _testExtra.oy * (h / sd.h));
      logEvent(_testExtra, now);
      return;
    }
    var res = lightningAt(seed, now - _testDelayMs, sd.w, sd.h, window.__wgtTest === true);

    if (res.alpha > 0) {
      var ev = res.event;
      // Stage points to backing pixels, at draw time only.
      var ox = ev.ox * (w / sd.w);
      var oy = ev.oy * (h / sd.h);
      drawFlash(ctx, w, h, res.alpha, ox, oy);
      logEvent(ev, now);
      if (window.__syncTest === true) {
        try {
          var pxA = ctx.getImageData(Math.min(Math.max(Math.round(ox), 0), w - 1), Math.min(Math.max(Math.round(oy), 0), h - 1), 1, 1).data[3];
          window.__wgtLastFlashPixel = { id: ev.id, alpha: res.alpha, pixelAlpha: pxA, at: now };
        } catch (e) {}
      }
      return;
    }

    ensureStats();
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
  }

  function init() {}
  function resize() {}

  var lightningEffect = {
    frame: frame,
    init: init,
    resize: resize
  };

  window.__wgtFlashAlpha = flashAlpha;
  window.__wgtLightningAt = lightningAt;
  window.__wgtLightningEvent = lightningEvent;

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
