#!/usr/bin/env python3
"""Analysis half of scripts/sync-check.sh (ow-blz.5 video sync, ow-blz.6 lightning sync).

Reads the ONLYWALLPAPERS_SYNC / ONLYWALLPAPERS_SYNC_EVENTS lines of one app run plus a marks file
(JSON lines {"name":..., "t":epoch_ms}) and evaluates the named checks. Prints SYNC_ASSERT lines
and one SYNC_RESULT line; exit status is the number of failed assertions (capped at 1).
"""
import argparse
import json
import re
import sys
from collections import defaultdict

SYNC_RE = re.compile(r"^ONLYWALLPAPERS_SYNC win=(\d+) idx=(\d+) (\{.*\})\s*$")
WIN_RE = re.compile(r"^ONLYWALLPAPERS_WINDOWS count=(\d+) gen=(\d+)")
EVT_RE = re.compile(r"^ONLYWALLPAPERS_SYNC_EVENTS win=(\d+) idx=(\d+) (\{.*\})\s*$")

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("marks")
ap.add_argument("--checks", required=True, help="comma list: windows,steady,seams,desync,rebuild,swap,lightning,newcomer,retire")
ap.add_argument("--fps", type=float, default=30.0)
ap.add_argument("--dur-a", type=float, required=True)
ap.add_argument("--dur-b", type=float, default=0.0)
ap.add_argument("--min-windows", type=int, default=2)
ap.add_argument("--settle-ms", type=float, default=4000)
ap.add_argument("--label", default="run")
ap.add_argument("--refresh-hz", type=float, default=60.0, help="display refresh used for the lightning draw-spread bound")
ap.add_argument("--driver-ms", type=float, default=33.0, help="period of the native test overlay frame driver")
ap.add_argument("--visible-only", action="store_true", help="ow-blz.8 phases: assert on visible, playing windows only (see visOk)")
ap.add_argument("--perf-from-ms", type=float, default=6000, help="ow-blz.8 perf check: start of the measured steady window, after the first sample of every window")
ap.add_argument("--perf-until", default="end", help="mark name that ends the perf window (default: end)")
ap.add_argument("--perf-max-seek-per-min", type=float, default=1.0)
ap.add_argument("--perf-min-fps-share", type=float, default=0.80)
ap.add_argument("--perf-min-rate1-share", type=float, default=0.95)
ap.add_argument("--perf-max-stall-ms", type=float, default=100.0)
ap.add_argument("--perf-seam-ms", type=float, default=400.0, help="bound on the largest presented-frame gap across a wrap")
ap.add_argument("--perf-abs-p95-ms", type=float, default=25.0, help="bound on the p95 of |presented error| against the timeline")
ap.add_argument("--perf-corr-gap-ms", type=float, default=600.0, help="bound on the largest presented-frame gap around a corrective seek")
ap.add_argument("--perf-allow-seek-timeouts", action="store_true", help="soak on a clip with an audio track (slow seeks): report seekTimeouts instead of asserting 0")
ap.add_argument("--pair-p95-ms", type=float, default=0.0, help="override the pairwise p95 bound (soak on a clip whose seeks are slow, see ow-blz.8)")
ap.add_argument("--pair-max-ms", type=float, default=0.0, help="override the pairwise max bound")
args = ap.parse_args()

FRAME_MS = 1000.0 / args.fps
THR_MS = max(FRAME_MS, 20.0)
# Comparison slack for float rounding only: two windows exactly one frame apart (33.333 ms against a
# 33.333 ms budget) are inside the budget.
THR_CMP = THR_MS + 0.05
PAIR_WINDOW_MS = 130.0

# Lightning first-draw spread bound. Every window computes the same strike start from the shared
# seed and wall clock, so the true cross-window skew is the clock/scheduling error (well under a
# frame). What is observable is the first DRAWN frame, and a window can only draw on a frame boundary:
#   base   = max(1 frame at the display refresh, 20 ms)   (the plan's budget)
#   margin = two native test-driver periods (2 x 33 ms)
# The margin is the rAF quantization of this harness. Occluded wallpaper windows get no rAF, so the
# test drives the overlay frame from a native 33 ms timer, uncorrelated between windows (one period
# of phase difference at first draw), and the driver skips a tick while a frame is still in flight
# (a 3 display canvas frame can outlast a period), which costs one more period. Measured on 3
# windows: median 16 ms, max 45 ms. The 200 ms falsifiability delay (measured 215 to 225 ms) still
# exceeds base + margin = 86 ms by more than 2x, so the bound stays discriminating.
LIGHT_BASE_MS = max(1000.0 / args.refresh_hz, 20.0)
LIGHT_MARGIN_MS = 2 * args.driver_ms
LIGHT_THR_MS = LIGHT_BASE_MS + LIGHT_MARGIN_MS

marks = {}
for line in open(args.marks):
    line = line.strip()
    if line:
        m = json.loads(line)
        marks[m["name"]] = m["t"]

samples = defaultdict(list)   # idx -> samples (sorted by now)
events = defaultdict(dict)    # idx -> id -> record
pixels = {}                   # idx -> last pixel record
connected = None              # screens the app reports it is driving (last ONLYWALLPAPERS_WINDOWS count)
for line in open(args.out, errors="replace"):
    m = WIN_RE.match(line)
    if m:
        connected = int(m.group(1))
        continue
    m = SYNC_RE.match(line)
    if m:
        d = json.loads(m.group(3))
        d["win"] = int(m.group(1))
        samples[int(m.group(2))].append(d)
        continue
    m = EVT_RE.match(line)
    if m:
        d = json.loads(m.group(3))
        for rec in d.get("events", []):
            events[int(m.group(2))].setdefault(rec["event"]["id"], rec)
        if d.get("pixel"):
            pixels[int(m.group(2))] = d["pixel"]
# A page the OS hides or occludes (a Space switch, a maximized window covering the display) is not
# visible to anyone: WebKit throttles it to about 30 Hz presented frames, may pause it and suspend its
# decoder, so its landing quality says nothing about what a user sees. The pairwise and perf assertions
# are about VISIBLE windows (the ow-blz.8 plan). Samples taken while hidden or paused, and for
# VIS_SETTLE_MS after the page was paused or its visibility changed (the controller re-joins after a 1 s
# debounce), carry visOk=False. The "windows-visible" assertion fails loudly when fewer than two
# windows were visible, so a covered display cannot make the gate vacuous.
VIS_SETTLE_MS = 5000
for idx in samples:
    samples[idx].sort(key=lambda s: s["now"])
    last_bad = -1e18
    prev_vis = None
    for smp in samples[idx]:
        vis = smp.get("vis", "visible")
        if smp["paused"] or vis != "visible" or (prev_vis is not None and vis != prev_vis):
            last_bad = smp["now"]
        prev_vis = vis
        smp["visOk"] = (not args.visible_only) or ((not smp["paused"]) and vis == "visible" and smp["now"] - last_bad >= VIS_SETTLE_MS)
    for smp in samples[idx]:
        # Presented-frame error (what is on screen against the timeline). Only a frame presented
        # recently and after the last seek counts; currentTime is logged for information only
        # because WebKit reports it with occasional 40 to 90 ms glitches.
        age = smp.get("presAgeMs", -1)
        since = smp.get("sinceSeekMs", -1)
        fresh = smp["errPres"] is not None and 0 <= age <= 300 and (since < 0 or since - age >= 30) and smp.get("postOk", True)
        smp["errPresFresh"] = smp["errPres"] if fresh else None

failures = 0


def assert_(name, ok, detail=""):
    global failures
    print("SYNC_ASSERT %s %s %s" % ("pass" if ok else "FAIL", name, detail))
    if not ok:
        failures += 1


def live_windows():
    return sorted(i for i, v in samples.items() if len(v) >= 20)


def nearest(lst, t):
    best = None
    bd = 1e18
    for s in lst:
        d = abs(s["now"] - t)
        if d < bd:
            best, bd = s, d
    return best, bd


# Samples taken while a window has a seek event in flight (join, wrap, corrective seek: the controller
# is mid-landing and re-seeks within about 150 ms when the landing is off) are not compared: their
# duration is bounded by the controller's token timeout and the per-window hitch/seek-budget/stall
# assertions cover how often and how long such events are.
def pairwise(t0, t1, rev=None, skip_seeking=True, key="errPresFresh", idxs=None, diffs_out=None):
    """Max pairwise |err_a - err_b| (ms) over [t0, t1] and the count of compared pairs.
    Every compared pair offset is appended to diffs_out when given (for the p50/p95/max statistic)."""
    ws = idxs if idxs is not None else live_windows()
    worst = 0.0
    n = 0
    worst_at = None
    for ai in range(len(ws)):
        for bi in range(ai + 1, len(ws)):
            a, b = ws[ai], ws[bi]
            for sa in samples[a]:
                if sa["now"] < t0 or sa["now"] > t1:
                    continue
                if rev is not None and sa["rev"] != rev:
                    continue
                if skip_seeking and sa["seeking"]:
                    continue
                if not sa["visOk"] or sa.get("tokenKind"):
                    continue
                if sa[key] is None:
                    continue
                sb, dist = nearest(samples[b], sa["now"])
                if sb is None or dist > PAIR_WINDOW_MS or sb[key] is None:
                    continue
                if rev is not None and sb["rev"] != rev:
                    continue
                if skip_seeking and sb["seeking"]:
                    continue
                if not sb["visOk"] or sb.get("tokenKind"):
                    continue
                diff = abs(sa[key] - sb[key]) * 1000.0
                n += 1
                if diffs_out is not None:
                    diffs_out.append(diff)
                if diff > worst:
                    worst, worst_at = diff, sa["now"]
    return worst, n, worst_at


# Video pairwise-offset statistic. The monitors' vsyncs are not genlocked, so up to one refresh of
# on-screen skew is inherent and one worst sample under machine load can exceed one frame. The bar is
# therefore: p95 of the pairwise offsets <= max(1 frame, 20 ms) AND max <= 2 frames. A constant offset
# (the +80 ms falsifiability run) violates p95 and still fails.
MAX_CMP = 2 * FRAME_MS + 0.05
if args.pair_p95_ms > 0:
    THR_CMP = args.pair_p95_ms + 0.05
if args.pair_max_ms > 0:
    MAX_CMP = args.pair_max_ms + 0.05


def pct(vals, q):
    v = sorted(vals)
    if not v:
        return 0.0
    k = (len(v) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def offset_assert(name, label, t0, t1, rev=None, min_n=10, idxs=None, extra=""):
    """Assert the p95/max pairwise-offset bar over [t0, t1] and print p50/p95/max. Returns max."""
    diffs = []
    worst, n, at = pairwise(t0, t1, rev=rev, idxs=idxs, diffs_out=diffs)
    p50, p95 = pct(diffs, 0.5), pct(diffs, 0.95)
    print("SYNC_METRIC %s_pairwise_ms p50=%.2f p95=%.2f max=%.2f pairs=%d" % (label, p50, p95, worst, n))
    assert_("%s<=p95:%.1fms,max:%.1fms" % (name, THR_MS, 2 * FRAME_MS), n >= min_n and p95 <= THR_CMP and worst <= MAX_CMP,
            "p50=%.2fms p95=%.2fms max=%.2fms pairs=%d%s" % (p50, p95, worst, n, extra))
    return worst, n, at


def first_all_samples():
    ws = live_windows()
    return max(samples[i][0]["now"] for i in ws) if ws else 0


def seams(epoch, dur, t0, t1):
    out = []
    k = int((t0 - epoch) // (dur * 1000.0)) + 1
    while epoch + k * dur * 1000.0 <= t1:
        out.append(epoch + k * dur * 1000.0)
        k += 1
    return out


def epoch_of(rev):
    for i in live_windows():
        for s in samples[i]:
            if s["rev"] == rev and s["epochMs"]:
                return s["epochMs"]
    return None


checks = args.checks.split(",")
t_first = first_all_samples()
t_end = marks.get("end", max((samples[i][-1]["now"] for i in samples), default=0))
steady_values = []

if "windows" in checks:
    ws = live_windows()
    vis_ws = [i for i in ws if sum(1 for x in samples[i] if x["visOk"]) >= 20]
    if args.visible_only:
      assert_("windows-visible>=%d" % args.min_windows, len(vis_ws) >= args.min_windows,
              "visible_windows=%d of %d (a display whose desktop is covered by a maximized window or a full-screen Space cannot be asserted on; set OW_SYNC_SINGLE_DISPLAY=1 to run the ow-blz.8 phases on two windows of the primary display)" % (len(vis_ws), len(ws)))
    assert_("windows>=%d" % args.min_windows, len(ws) >= args.min_windows, "live_windows=%d" % len(ws))
    assert_("sampled-windows==connected-screens", connected is not None and len(ws) == connected and len(set(samples[i][0]["win"] for i in ws)) == connected,
            "sampled=%d distinct_win=%d connected=%s" % (len(ws), len(set(samples[i][0]["win"] for i in ws)), connected))
    firsts = {}
    for i in ws:
        last = samples[i][-1]
        firsts[i] = (last["rev"], last["epochMs"], last["durationSec"])
    sess_a = [(s["epochMs"], s["durationSec"]) for i in ws for s in samples[i][:1]]
    assert_("session-identical-across-windows", len(set(sess_a)) == 1, str(sorted(set(sess_a))))
    assert_("duration-probed-natively", ws and all(abs(samples[i][0]["durationSec"] - args.dur_a) < 0.05 for i in ws),
            "probed=%s expected=%.3f" % (sorted(set(samples[i][0]["durationSec"] for i in ws)), args.dur_a))
    # A window the OS has hidden is paused by WebKit; that is not a controller failure.
    assert_("all-windows-playing", ws and all(not samples[i][-1]["paused"] or samples[i][-1].get("vis", "visible") != "visible" for i in ws))

if "steady" in checks:
    end = marks.get("desync", marks.get("rebuild", marks.get("swap", t_end)))
    t0 = t_first + args.settle_ms
    worst, n, at = offset_assert("steady-state-pairwise-offset", "steady", t0, end, rev=0, min_n=20,
                                 extra=" window=[+%.1fs,+%.1fs]" % ((t0 - t_first) / 1000, (end - t_first) / 1000))
    steady_values.append(worst)
    cw, cn, _ = pairwise(t0, end, rev=0, key="errCur")
    print("SYNC_METRIC steady_max_pairwise_currentTime_ms=%.2f pairs=%d (informational: WebKit currentTime is glitchy)" % (cw, cn))

if "seams" in checks:
    end = marks.get("desync", t_end)
    t0 = t_first + args.settle_ms
    ep = epoch_of(0)
    sm = seams(ep, args.dur_a, t0, end) if ep else []
    assert_("seams-crossed>=3", len(sm) >= 3, "seams=%d" % len(sm))
    worst_c = 0.0
    nn = 0
    seam_diffs = []
    for t in sm:
        w, n, _ = pairwise(t - 500, t + 1200, rev=0, diffs_out=seam_diffs)
        worst_c = max(worst_c, w)
        nn += n
    # Plan bar (ow-blz.8): p95 <= max(1 frame, 20 ms) and max <= 2 frames, seams included. Two windows
    # one frame apart plus a few ms of presentation jitter are inside it; the old bar (max <= 1 frame)
    # failed on 60 fps clips for exactly that.
    sp95 = pct(seam_diffs, 0.95)
    print("SYNC_METRIC seam_pairwise_ms p95=%.2f max=%.2f pairs=%d" % (sp95, worst_c, nn))
    assert_("seam-pairwise-presented<=p95:%.1fms,max:%.1fms" % (THR_MS, 2 * FRAME_MS), nn >= 3 * 3 and sp95 <= THR_CMP and worst_c <= MAX_CMP,
            "p95=%.2fms max=%.2fms pairs=%d" % (sp95, worst_c, nn))
    # Every window actually wrapped (its media time dropped by more than half a clip) at each seam.
    wrapped = 0
    for i in live_windows():
        prev = None
        for s in samples[i]:
            if s["rev"] != 0 or s["now"] < t0 or s["now"] > end:
                prev = None
                continue
            if prev is not None and prev["currentTime"] - s["currentTime"] > args.dur_a / 2:
                wrapped += 1
            prev = s
    assert_("every-window-wrapped-each-seam", wrapped >= len(sm) * len(live_windows()) - len(live_windows()),
            "wraps=%d expected~=%d" % (wrapped, len(sm) * len(live_windows())))

if "desync" in checks:
    td = marks["desync"]
    ws = live_windows()
    target_idx = 1 if 1 in ws else ws[-1]
    # OBSERVED deviation only: the presented-frame error (errPres) of the targeted window right after
    # the hook. The window records every presented frame for 1.5 s after the hook (desyncTrace), because
    # the controller corrects within one 250 ms tick, faster than this 250 ms sampler. The hook's
    # self-reported desyncAppliedErr is deliberately NOT used.
    seen = 0.0
    nobs = 0
    for s in samples[target_idx]:
        if td <= s["now"] <= td + 2000 and s["errPres"] is not None:
            seen = max(seen, abs(s["errPres"]))
            nobs += 1
        for rec in (s.get("desyncTrace") or []):
            seen = max(seen, abs(rec["errPres"]))
            nobs += 1
    assert_("desync-hook-took-effect", seen >= 1.0, "max|errPres|=%.3fs observed_frames=%d" % (seen, nobs))
    # Reconverged = the last presented-frame sample outside the threshold (stale pre-seek frames
    # count: they are what was still on screen), then the next sample inside it.
    horizon = td + 5000
    bad_after = td
    for s in samples[target_idx]:
        if s["now"] < td or s["now"] > horizon or s["errPres"] is None:
            continue
        if abs(s["errPres"]) * 1000.0 > THR_MS:
            bad_after = s["now"]
    nxt = [s["now"] for s in samples[target_idx] if s["now"] > bad_after and s["errPres"] is not None]
    t_conv_end = (nxt[0] - td) if nxt else 1e9
    assert_("desync-reconverges<=1500ms", t_conv_end <= 1500 + 250, "converged_at=+%.0fms (last bad +%.0fms, sampling 250ms)" % (t_conv_end, bad_after - td))
    # A seek lands within about half a frame; rate nudges (at most 1%) remove the rest, so the
    # tight bound applies from 1.5 s after the reconvergence point.
    worst, n, _ = pairwise(td + t_conv_end + 1500, horizon + 1500)
    assert_("desync-stays-converged", n >= 3 and worst <= THR_CMP, "max=%.2fms pairs=%d" % (worst, n))

if "rebuild" in checks:
    tr = marks["rebuild"]
    end = marks.get("swap", t_end)
    offset_assert("rebuild-keeps-alignment", "rebuild", tr, end - 500)
    ws = live_windows()
    eps = set((s["epochMs"], s["rev"]) for i in ws for s in samples[i] if tr <= s["now"] <= end)
    assert_("rebuild-session-tuple-unchanged", len(eps) == 1, str(sorted(eps)))

if "swap" in checks:
    tsw = marks["swap"]
    ws = live_windows()
    last_rev = {i: samples[i][-1]["rev"] for i in ws}
    assert_("swap-all-windows-on-new-rev", all(r == 1 for r in last_rev.values()), str(last_rev))
    new = [(s["epochMs"], s["durationSec"]) for i in ws for s in samples[i] if s["rev"] == 1 and s["now"] > tsw + 3000]
    assert_("swap-session-identical-and-probed", len(set(new)) == 1 and abs(new[0][1] - args.dur_b) < 0.05,
            "new=%s expected_dur=%.3f" % (sorted(set(new)), args.dur_b))
    t_sw_end = marks.get("reload", t_end)
    t0 = tsw + args.settle_ms
    worst, n, at = offset_assert("swap-steady-pairwise", "swap", t0, t_sw_end, rev=1, min_n=20)
    steady_values.append(worst)
    ep = epoch_of(1)
    sm = seams(ep, args.dur_b, t0, t_sw_end) if ep and args.dur_b > 0 else []
    assert_("swap-seams-crossed>=2", len(sm) >= 2, "seams=%d" % len(sm))
    # Convergence time on the new rev: first sample from which every window pair stays aligned.
    conv = None
    for s in sorted((s for i in ws for s in samples[i] if s["rev"] == 1), key=lambda s: s["now"]):
        w, n, _ = pairwise(s["now"], t_sw_end, rev=1)
        if n >= 10 and w <= THR_MS:
            conv = s["now"] - tsw
            break
    assert_("swap-converges<=4000ms", conv is not None and conv <= 4000, "converged=+%sms" % (None if conv is None else int(conv)))

if "newcomer" in checks:
    tn = marks["newcomer"]
    ws = live_windows()
    late = [i for i in samples if samples[i] and samples[i][0]["now"] >= tn - 500]
    assert_("newcomer-window-appeared", len(late) >= 1, "late_windows=%s live=%s" % (late, ws))
    all_ws = sorted(set(ws) | set(i for i in late if len(samples[i]) >= 8))
    assert_("newcomer-sampled-windows==connected-screens", connected is not None and len(all_ws) == connected, "sampled=%d connected=%s" % (len(all_ws), connected))
    t0 = tn + args.settle_ms
    offset_assert("newcomer-aligned", "newcomer", t0, t_end, rev=0, idxs=all_ws, extra=" windows=%s" % all_ws)
    sess = set((s["epochMs"], s["rev"], s["durationSec"]) for i in all_ws for s in samples[i])
    assert_("newcomer-same-session-tuple", len(sess) == 1, str(sorted(sess)))
    first_new = min(samples[i][0]["now"] for i in late) if late else 0
    worst_n, n_n, _ = pairwise(first_new + 3000, first_new + 6000, rev=0, idxs=all_ws)
    print("SYNC_METRIC newcomer_first_3s_after_join_max_ms=%.2f pairs=%d" % (worst_n, n_n))

if "retire" in checks:
    # Fake screens 3 -> 2 with the FIRST display (did 101) removed, so both survivors move down one
    # index. The marks file carries "retire" (just before the rebuild signal) and "cmd" (the routed
    # desync command, sent after the rebuild settled).
    tr = marks["retire"]
    tc = marks["cmd"]
    retired_lines = [l for l in open(args.out, errors="replace") if l.startswith("ONLYWALLPAPERS_RETIRE ")]
    retired_wins = [int(re.search(r"win=(\d+)", l).group(1)) for l in retired_lines]
    assert_("retire-one-view-retired", len(retired_wins) == 1 and retired_wins[0] != 0, "retired_wins=%s" % retired_wins)
    inval = [l for l in open(args.out, errors="replace") if l.startswith("ONLYWALLPAPERS_VIEW_RETIRED ")]
    assert_("retire-timers-invalidated", len(inval) == 1 and "timers_invalidated=2" in inval[0], "lines=%s" % [l.strip() for l in inval])
    rw = retired_wins[0] if retired_wins else -1
    gone = [s for i in samples for s in samples[i] if s["win"] == rw]
    before = [s for s in gone if s["now"] < tr]
    after = [s for s in gone if s["now"] > tr + 1500]
    assert_("retired-view-stops-emitting", len(before) >= 20 and not after,
            "retired_win=%d samples_before=%d samples_after=%d" % (rw, len(before), len(after)))
    # The surviving windows keep emitting, and under their NEW index (the old index no longer exists).
    win_idx = defaultdict(set)
    for i in samples:
        for s in samples[i]:
            if s["win"] != rw and s["now"] > tr + 3000:
                win_idx[s["win"]].add(i)
    assert_("survivors-reindexed-to-0..n-1", len(win_idx) == 2 and sorted(i for v in win_idx.values() for i in v) == [0, 1] and all(len(v) == 1 for v in win_idx.values()),
            "win->idx=%s connected=%s" % ({w: sorted(v) for w, v in win_idx.items()}, connected))
    assert_("retire-sampled-windows==connected-screens", connected is not None and len(win_idx) == connected, "sampled=%d connected=%s" % (len(win_idx), connected))
    # "desync 0" must land on the window that is NOW index 0 and on no other.
    hit = defaultdict(float)
    for i in samples:
        for s in samples[i]:
            if s["win"] != rw and s["now"] >= tc and s.get("desyncAppliedErr") is not None:
                hit[(i, s["win"])] = max(hit[(i, s["win"])], abs(s["desyncAppliedErr"]))
    assert_("routed-command-hits-new-index-0-only", sorted(k[0] for k, v in hit.items() if v > 1.0) == [0], "hit=%s" % {str(k): round(v, 2) for k, v in hit.items()})

if "reload" in checks:
    # A view reloaded after a swap (the same path as a web content process restart) starts from the
    # document-start session of its creation (rev 0) and must end on the controller's LATEST rev.
    tr = marks["reload"]
    ws = live_windows()
    target_idx = 1 if 1 in ws else ws[-1]
    after = [s for s in samples[target_idx] if s["now"] > tr]
    revs_after = sorted(set(s["rev"] for s in after))
    assert_("reload-view-ends-on-latest-rev", bool(after) and after[-1]["rev"] == 1 and all(samples[i][-1]["rev"] == 1 for i in ws),
            "reloaded_idx=%d revs_after=%s last=%s" % (target_idx, revs_after, {i: samples[i][-1]["rev"] for i in ws}))
    ep_all = set((samples[i][-1]["epochMs"], samples[i][-1]["durationSec"]) for i in ws)
    assert_("reload-session-identical-across-windows", len(ep_all) == 1, str(sorted(ep_all)))
    t0 = tr + args.settle_ms
    worst, n, _ = offset_assert("reload-aligned", "reload", t0, t_end, rev=1,
                                extra=" window=[+%.1fs,+%.1fs]" % ((t0 - tr) / 1000, (t_end - tr) / 1000))
    steady_values.append(worst)

if "probefail" in checks:
    # Native AVURLAsset probe forced to fail (OW_SYNC_TEST_PROBE_FAIL): the first view's metadata
    # duration must be adopted once and broadcast, so every window reports the SAME duration.
    ws = live_windows()
    adopted = [l for l in open(args.out, errors="replace") if l.startswith("ONLYWALLPAPERS_SESSION adopted")]
    assert_("probefail-duration-adopted-from-first-view", len(adopted) >= 1, "adopted_lines=%d" % len(adopted))
    # Last rev 0 sample of every window (before any swap).
    last = {}
    for i in ws:
        r0 = [s for s in samples[i] if s["rev"] == 0]
        if r0:
            last[i] = (r0[-1]["durationSec"], r0[-1]["epochMs"], r0[-1]["joined"])
    durs = set(v[0] for v in last.values())
    assert_("probefail-sampled-windows==connected-screens", connected is not None and len(ws) == connected, "sampled=%d connected=%s" % (len(ws), connected))
    assert_("probefail-one-shared-duration", len(ws) >= args.min_windows and len(last) == len(ws) and len(durs) == 1 and all(abs(d - args.dur_a) < 0.05 for d in durs) and all(v[2] for v in last.values()),
            "durations=%s expected=%.3f" % (last, args.dur_a))
    # No window may ever report a nonzero duration that differs from the adopted one (no per-element duration).
    seen = set(round(s["durationSec"], 4) for i in ws for s in samples[i] if s["durationSec"] and s["rev"] == 0)
    assert_("probefail-no-per-element-duration", len(seen) <= 1, str(sorted(seen)))
    tsw = marks.get("swap")
    end = marks.get("reload", marks.get("swap", t_end))
    t0 = t_first + args.settle_ms
    t1 = tsw if tsw else t_end
    worst, n, _ = offset_assert("probefail-steady-pairwise", "probefail_steady", t0, t1, rev=0, min_n=20)
    steady_values.append(worst)
    if tsw:
        nd = set(round(s["durationSec"], 4) for i in ws for s in samples[i] if s["rev"] == 1 and s["durationSec"])
        assert_("probefail-swap-one-shared-duration", len(nd) == 1 and abs(list(nd)[0] - args.dur_b) < 0.05, "durations=%s expected=%.3f" % (sorted(nd), args.dur_b))
        offset_assert("probefail-swap-aligned", "probefail_swap", tsw + args.settle_ms, t_end, rev=1)

if "perf" in checks:
    # ow-blz.8: per-window health of the controller on a high frame rate clip. The ow-blz.5 loop
    # kept pairwise offsets inside a frame by seeking every tick, which starved a 4K60 decoder
    # (95 seeks/min, presented error p50 200 ms). These assertions are on each window alone.
    t0 = t_first + args.perf_from_ms
    t1 = marks.get(args.perf_until, t_end)
    ws = [i for i in live_windows()]
    # A stall that hits every window at the same moment (+-1 s) is a host event (WindowServer, a
    # display waking up), not controller behaviour: it is reported, not asserted on.
    stall_at = {}
    for i in ws:
        ev = []
        for a, b in zip(samples[i], samples[i][1:]):
            if b["stallsOut"] > a["stallsOut"]:
                ev.append(b["now"])
        stall_at[i] = ev
    def own_stalls(i, lo, hi):
        n = 0
        for t in stall_at[i]:
            if not (lo <= t <= hi):
                continue
            if len(ws) > 1 and all(any(abs(t - u) <= 1000 for u in stall_at[j]) for j in ws if j != i):
                continue
            n += 1
        return n
    for i in ws:
        allsm = [x for x in samples[i] if t0 <= x["now"] <= t1 and x["rev"] == 0 and x.get("presentedFrames") is not None]
        sm = [x for x in allsm if x["visOk"]]
        if len(sm) < 8:
            assert_("perf-w%d-enough-visible-samples" % i, False, "visible_samples=%d of %d" % (len(sm), len(allsm)))
            continue
        # Counters are cumulative per document: sum deltas over consecutive visible samples only
        # (a hidden stretch or a reload in between is skipped, not averaged in).
        wall = 0.0
        pf = 0
        corr = joins = wraps = seeks_all = stalls = timeouts = 0
        for a, b in zip(allsm, allsm[1:]):
            if not (a["visOk"] and b["visOk"]) or b["now"] - a["now"] > 600:
                continue
            d = b["presentedFrames"] - a["presentedFrames"]
            if d < 0:
                continue
            wall += (b["now"] - a["now"]) / 1000.0
            pf += d
            corr += b["corrSeeks"] - a["corrSeeks"]
            joins += b["joinSeeks"] - a["joinSeeks"]
            wraps += b["wrapSeeks"] - a["wrapSeeks"]
            seeks_all += b["seeks"] - a["seeks"]
            timeouts += b["seekTimeouts"] - a["seekTimeouts"]
        stalls = own_stalls(i, allsm[0]["now"], allsm[-1]["now"])
        host_stalls = len(stall_at[i]) - stalls
        mins = max(wall / 60.0, 1e-6)
        seek_budget = max(args.perf_max_seek_per_min * mins, 1.0)
        fps = pf / wall if wall > 0 else 0.0
        maxgap = max(x["maxGapOut"] for x in sm)
        seam = max(x["seamGapMax"] for x in sm)
        corrgap = max(x["corrGapMax"] for x in sm)
        rate1 = sum(1 for x in sm if abs(x["rate"] - 1.0) < 1e-6) / float(len(sm))
        ab = sorted(abs(x["errPresFresh"]) * 1000.0 for x in sm if x["errPresFresh"] is not None)
        a50, a95, amax = pct(ab, 0.5), pct(ab, 0.95), (ab[-1] if ab else 0.0)
        # The counters partition all seeks: every sample (counters are cumulative per document).
        bad_part = [x for x in sm if x["joinSeeks"] + x["wrapSeeks"] + x["corrSeeks"] != x["seeks"]]
        print("SYNC_METRIC perf_w%d seeks_total=%d corr=%d wrap=%d join=%d seeks_per_min=%.2f fps=%.1f fps_share=%.3f rate1_share=%.3f stalls_out=%d host_wide_stalls=%d max_gap_out_ms=%.0f seam_gap_max_ms=%.0f corr_gap_max_ms=%.0f abs_err_p50=%.1f p95=%.1f max=%.1f window_s=%.0f lead=%.3f/%.3f latency=%.3f" % (
            i, seeks_all, corr, wraps, joins, corr / mins, fps, fps / args.fps, rate1, stalls, host_stalls, maxgap, seam, corrgap, a50, a95, amax, wall,
            sm[-1]["leadSeek"], sm[-1]["leadWrap"], sm[-1]["seekLatency"]))
        assert_("perf-w%d-corrective-seeks<=%.1f/min" % (i, args.perf_max_seek_per_min), corr <= seek_budget, "corr=%d budget=%.1f over %.0fs" % (corr, seek_budget, wall))
        assert_("perf-w%d-seek-counters-partition(join+wrap+corr==total)" % i, not bad_part, "bad_samples=%d first=%s" % (len(bad_part), ("%d+%d+%d!=%d" % (bad_part[0]["joinSeeks"], bad_part[0]["wrapSeeks"], bad_part[0]["corrSeeks"], bad_part[0]["seeks"])) if bad_part else "-"))
        assert_("perf-w%d-seekTimeouts==0" % i, timeouts == 0 or args.perf_allow_seek_timeouts, "seek_timeouts=%d" % timeouts)
        assert_("perf-w%d-presented-fps>=%.0f%%nominal" % (i, 100 * args.perf_min_fps_share), fps >= args.perf_min_fps_share * args.fps, "fps=%.1f nominal=%.1f" % (fps, args.fps))
        assert_("perf-w%d-rate==1.0-in>=%.0f%%" % (i, 100 * args.perf_min_rate1_share), rate1 >= args.perf_min_rate1_share, "share=%.3f" % rate1)
        assert_("perf-w%d-no-stall>%.0fms-outside-join-wrap" % (i, args.perf_max_stall_ms), stalls == 0, "stalls=%d max_gap=%.0fms" % (stalls, maxgap))
        assert_("perf-w%d-seam-hitch<=%.0fms" % (i, args.perf_seam_ms), seam <= args.perf_seam_ms, "seam_gap_max=%.0fms" % seam)
        assert_("perf-w%d-corrective-seek-hitch<=%.0fms" % (i, args.perf_corr_gap_ms), corrgap <= args.perf_corr_gap_ms, "corr_gap_max=%.0fms" % corrgap)
        assert_("perf-w%d-abs-presented-err-p95<=%.0fms" % (i, args.perf_abs_p95_ms), len(ab) >= 8 and a95 <= args.perf_abs_p95_ms, "p50=%.1f p95=%.1f max=%.1f n=%d" % (a50, a95, amax, len(ab)))

if "lightning" in checks:
    ws = sorted(events.keys())
    assert_("lightning-events-from>=2-windows", len(ws) >= args.min_windows, "windows=%s" % ws)
    assert_("lightning-events-from-every-connected-screen", connected is not None and len(ws) == connected, "event_windows=%d connected=%s" % (len(ws), connected))
    per = {i: events[i] for i in ws}
    common = set.intersection(*[set(per[i].keys()) for i in ws]) if ws else set()
    assert_("lightning-common-events>=3", len(common) >= 3, "common=%d per-window=%s" % (len(common), {i: len(per[i]) for i in ws}))
    ident = True
    detail = ""
    for eid in sorted(common, key=str):
        recs = set(json.dumps(per[i][eid]["event"], sort_keys=True) for i in ws)
        if len(recs) != 1:
            ident = False
            detail = "id=%s differs: %s" % (eid, sorted(recs))
            break
    assert_("lightning-event-records-identical", len(common) >= 3 and ident, detail or "ids=%d" % len(common))
    # The SET of strikes must be identical across windows over the time span every window observed
    # (so one display drawing an extra independent strike, or missing one, fails). Each window's
    # observed span is its first to last sample time, trimmed for the first draw delay and the 1 s
    # event poll lag. Strikes overlapping a rebuild, reload or newcomer disturbance are excluded:
    # a restarting document cannot log a strike, by construction.
    obs_lo = max(samples[i][0]["now"] + 1000 for i in ws if samples[i]) if ws else 0
    obs_hi = min(samples[i][-1]["now"] - 1500 for i in ws if samples[i]) if ws else 0
    set_disturbed = [(marks[k] - 1500, marks[k] + 3000) for k in ("rebuild", "reload", "newcomer") if k in marks]
    def in_span(ev):
        return ev["start"] >= obs_lo and ev["end"] <= obs_hi and not any(ev["end"] >= a and ev["start"] <= b for a, b in set_disturbed)
    sets = {i: set(str(eid) for eid, rec in per[i].items() if in_span(rec["event"])) for i in ws}
    union = set().union(*sets.values()) if sets else set()
    odd = {i: sorted(union - sets[i]) for i in ws if sets[i] != union}
    assert_("lightning-event-sets-identical-in-common-span", len(union) >= 3 and not odd,
            "span=[+%.1fs,+%.1fs] events=%d windows_differing=%s" % ((obs_lo - t_first) / 1000, (obs_hi - t_first) / 1000, len(union),
                                                                       {i: "missing %s" % v for i, v in odd.items()}))
    # A window that is being rebuilt or reloaded (its document and overlay restart, about 0.5 s) or that
    # has not started yet cannot draw a strike on time, by construction. Strikes overlapping those
    # disturbances are excluded from the spread (their record identity is still asserted above).
    DISTURB_MS = 3000
    disturbed = [(marks[k], marks[k] + DISTURB_MS) for k in ("rebuild", "reload", "newcomer") if k in marks]
    spreads = []
    skipped = 0
    for eid in common:
        ev = per[ws[0]][eid]["event"]
        if ev["start"] < t_first or any(ev["end"] >= a and ev["start"] <= b for a, b in disturbed):
            skipped += 1
            continue
        ts = [per[i][eid]["firstDrawnAt"] for i in ws]
        spreads.append(max(ts) - min(ts))
    print("SYNC_METRIC lightning_events_excluded_for_rebuild_reload_or_startup=%d of %d" % (skipped, len(common)))
    if spreads:
        print("SYNC_METRIC lightning_first_draw_spread_ms max=%d median=%d bound=%.1f" % (max(spreads), sorted(spreads)[len(spreads) // 2], LIGHT_THR_MS))
    assert_("lightning-first-draw-spread<=%.1fms" % LIGHT_THR_MS, len(spreads) >= 3 and max(spreads) <= LIGHT_THR_MS,
            "max=%dms events=%d (base %.1f + margin %.0f)" % (max(spreads) if spreads else -1, len(spreads), LIGHT_BASE_MS, LIGHT_MARGIN_MS))
    px_ok = bool(pixels) and len(pixels) >= args.min_windows and all(
        p["pixelAlpha"] > 0 and p["pixelAlpha"] >= int(p["alpha"] * 255 * 0.9) for p in pixels.values())
    assert_("lightning-pixel-readback-at-origin", px_ok, json.dumps(pixels, sort_keys=True)[:400])

print("SYNC_RESULT label=%s failures=%d steady_max_ms=%s thr_ms=%.2f" % (
    args.label, failures, ",".join("%.2f" % v for v in steady_values) or "n/a", THR_MS))
sys.exit(1 if failures else 0)
