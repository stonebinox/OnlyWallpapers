// Frozen-timestamp checks of the pure lightning function (ow-blz.6). Run by scripts/sync-check.sh.
// wallpaper.js is loaded into a vm with no DOM (every IIFE that needs an element returns early),
// Date.now, performance.now and rAF throw inside the pure function and Math.random throws, so any hidden clock or RNG dependence fails here.
"use strict";
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "..", "Sources", "OnlyWallpapers", "web", "wallpaper.js"), "utf8");
const sandbox = {
  document: { getElementById: () => null, addEventListener: () => {}, visibilityState: "visible" },
  console,
  Math: Object.create(Math, { random: { value: () => { throw new Error("Math.random on the lightning path"); } } }),
  Date: { now: () => { throw new Error("Date.now read inside the pure function"); } },
  performance: { now: () => { throw new Error("performance.now read inside the pure function"); } },
  requestAnimationFrame: () => { throw new Error("rAF on the lightning path"); },
  devicePixelRatio: 1,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(src, sandbox);

let pass = 0, fail = 0;
function check(name, cond) {
  console.log(`LIGHTNING_PURE ${cond ? "pass" : "FAIL"} ${name}`);
  if (cond) pass++; else fail++;
}

const at = sandbox.__wgtLightningAt;
const ev = sandbox.__wgtLightningEvent;
const flash = sandbox.__wgtFlashAlpha;
check("functions-exposed", typeof at === "function" && typeof ev === "function" && typeof flash === "function");

const W = 5760, H = 2160, SEED = 20260518;
const J = (x) => JSON.stringify(x);

for (const test of [true, false]) {
  const label = test ? "test" : "prod";
  const slotMs = test ? 3000 : 37500;
  const spanMs = test ? 1000 : 22500;
  const e = ev(SEED, 100, W, H, test);
  check(`${label}-deterministic`, J(e) === J(ev(SEED, 100, W, H, test)));
  check(`${label}-order-independent`, (() => { ev(SEED, 7, W, H, test); ev(SEED, 99999, W, H, test); return J(e) === J(ev(SEED, 100, W, H, test)); })());
  check(`${label}-seed-changes-schedule`, J(e) !== J(ev(SEED + 1, 100, W, H, test)));
  check(`${label}-slot-changes-event`, J(e) !== J(ev(SEED, 101, W, H, test)));
  check(`${label}-start-inside-slot`, e.start >= 100 * slotMs && e.start <= 100 * slotMs + spanMs);
  check(`${label}-ends-inside-slot`, e.end < 101 * slotMs);
  check(`${label}-origin-in-stage-points`, e.ox >= 0 && e.ox <= W && e.oy >= 0 && e.oy <= H * 0.4);
  check(`${label}-flicker-count`, e.flickers.length >= 2 && e.flickers.length <= 4);
  check(`${label}-peak-range`, e.peak >= 0.25 && e.peak <= 0.85);
  check(`${label}-flicker-gaps`, e.flickers.every((f, i) => i === 0 || (f - e.flickers[i - 1] - 140 >= 40 && f - e.flickers[i - 1] - 140 <= 110)));
  check(`${label}-origin-scales-with-stage`, Math.abs(ev(SEED, 100, W / 2, H, test).ox * 2 - e.ox) < 0.05);

  // Gaps between consecutive bursts stay inside the production (15 to 60 s) / test (2 to 4 s) range.
  let lo = Infinity, hi = 0;
  let prev = ev(SEED, 0, W, H, test).start;
  for (let s = 1; s < 5000; s++) {
    const st = ev(SEED, s, W, H, test).start;
    lo = Math.min(lo, st - prev); hi = Math.max(hi, st - prev); prev = st;
  }
  const gLo = test ? 2000 : 15000, gHi = test ? 4000 : 60000;
  check(`${label}-gap-range-${gLo}-${gHi}`, lo >= gLo && hi <= gHi);
  check(`${label}-gap-range-is-used`, lo < gLo + (gHi - gLo) * 0.1 && hi > gHi - (gHi - gLo) * 0.1);

  // Frozen timestamps: alpha at fixed offsets from the burst start is the envelope, nothing else.
  const t0 = e.start + e.flickers[0];
  const r0 = at(SEED, t0 - 1, W, H, test);
  check(`${label}-frozen-before-start-zero`, r0.alpha === 0);
  check(`${label}-frozen-at-start-zero`, at(SEED, t0, W, H, test).alpha === 0);
  check(`${label}-frozen-mid-rise`, Math.abs(at(SEED, t0 + 10, W, H, test).alpha - e.peak * 0.5) < 1e-12);
  check(`${label}-frozen-peak`, Math.abs(at(SEED, t0 + 20, W, H, test).alpha - e.peak) < 1e-12);
  check(`${label}-frozen-decay-60`, Math.abs(at(SEED, t0 + 80, W, H, test).alpha - e.peak * Math.exp(-3.5 / 120 * 60)) < 1e-12);
  check(`${label}-frozen-decay-end-zero`, at(SEED, t0 + 140, W, H, test).alpha === 0);
  check(`${label}-frozen-between-flickers-zero`, e.flickers.length < 2 || at(SEED, e.start + e.flickers[1] - 1, W, H, test).alpha === 0);
  check(`${label}-frozen-second-flicker-peak`, e.flickers.length < 2 || Math.abs(at(SEED, e.start + e.flickers[1] + 20, W, H, test).alpha - e.peak) < 1e-12);
  check(`${label}-frozen-after-burst-zero`, at(SEED, e.end, W, H, test).alpha === 0 && at(SEED, (101) * slotMs - 1, W, H, test).alpha === 0);
  check(`${label}-same-instant-same-result`, J(at(SEED, t0 + 33, W, H, test)) === J(at(SEED, t0 + 33, W, H, test)));
  check(`${label}-envelope-matches-flashAlpha`, Math.abs(at(SEED, t0 + 55, W, H, test).alpha - flash(55, e.peak)) < 1e-12);
}

// The envelope shape is the original LOOK: 20 ms linear rise, 120 ms exponential decay to ~3%.
check("envelope-rise-linear", Math.abs(flash(10, 0.7) - 0.35) < 1e-12 && Math.abs(flash(20, 0.7) - 0.7) < 1e-12);
check("envelope-decay-k", Math.abs(flash(140 - 1e-9, 1) - Math.exp(-3.5)) < 1e-6);
check("envelope-outside-zero", flash(-1, 1) === 0 && flash(140, 1) === 0);

console.log(`LIGHTNING_PURE summary pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
