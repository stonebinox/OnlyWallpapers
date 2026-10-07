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
    var hm = /hue-rotate\(([\d.]+)deg\)/.exec(f);
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
