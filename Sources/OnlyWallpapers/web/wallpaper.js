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
