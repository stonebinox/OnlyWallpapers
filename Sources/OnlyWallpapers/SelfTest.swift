import Foundation
import CoreGraphics

enum SelfTest {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            let result = condition ? "pass" : "fail"
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SELFTEST name=\(name) result=\(result)\n".utf8))
            if condition { passed += 1 } else { failed += 1 }
        }

        // arrangementChanged tests
        let d1 = ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let d2 = ScreenDescriptor(displayID: 2, frame: CGRect(x:1920, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let d1b = ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)

        check("arrangementChanged-same", !arrangementChanged(committed: [d1, d2], next: [d2, d1]))
        check("arrangementChanged-diff-frame", arrangementChanged(committed: [d1], next: [ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:2560, height:1440), scale:2, pixelW:5120, pixelH:2880)]))
        check("arrangementChanged-diff-count", arrangementChanged(committed: [d1], next: [d1, d2]))
        check("arrangementChanged-empty-empty", !arrangementChanged(committed: [], next: []))
        check("arrangementChanged-copy", !arrangementChanged(committed: [d1], next: [d1b]))

        // computeLayout tests
        let (union1, slices1) = computeLayout([CGRect(x:0, y:0, width:1920, height:1080)])
        check("computeLayout-single-union-w", abs(union1.width - 1920) < 0.5)
        check("computeLayout-single-union-h", abs(union1.height - 1080) < 0.5)
        check("computeLayout-single-offX", abs(slices1[0].offX) < 0.5)
        check("computeLayout-single-offY", abs(slices1[0].offY) < 0.5)

        // T-shape: two 3840x2160 side by side above a 1920x1080 centered at x=1920
        let left4k  = CGRect(x:0,    y:1080, width:3840, height:2160)
        let right4k = CGRect(x:3840, y:1080, width:3840, height:2160)
        let bot1080 = CGRect(x:1920, y:0,    width:1920, height:1080)
        let (tUnion, tSlices) = computeLayout([left4k, right4k, bot1080])
        check("computeLayout-tshape-union-w", abs(tUnion.width - 7680) < 0.5)
        check("computeLayout-tshape-union-h", abs(tUnion.height - 3240) < 0.5)
        check("computeLayout-tshape-left-offX", abs(tSlices[0].offX) < 0.5)
        check("computeLayout-tshape-left-offY", abs(tSlices[0].offY) < 0.5)
        check("computeLayout-tshape-right-offX", abs(tSlices[1].offX - 3840) < 0.5)
        check("computeLayout-tshape-bottom-offX", abs(tSlices[2].offX - 1920) < 0.5)
        check("computeLayout-tshape-bottom-offY", abs(tSlices[2].offY - 2160) < 0.5)

        // Reducer tests
        var r = WallpaperRefreshReducer()
        let committed: [ScreenDescriptor] = [d1]

        // idle + non-empty same = noop
        let a1 = r.snapshot([d1], committed: committed)
        check("reducer-idle-same-noop", a1 == .none)
        check("reducer-idle-same-state", r.pendingState == .idle)

        // idle + non-empty different = scheduleDebounce
        var r2 = WallpaperRefreshReducer()
        let a2 = r2.snapshot([d2], committed: committed)
        check("reducer-idle-diff-debounce", a2 == .scheduleDebounce)
        if case .debouncePending(let n) = r2.pendingState {
            check("reducer-idle-diff-state", n == [d2])
        } else {
            check("reducer-idle-diff-state", false)
        }

        // idle + empty = scheduleEmptyConfirm
        var r3 = WallpaperRefreshReducer()
        let a3 = r3.snapshot([], committed: committed)
        check("reducer-idle-empty-confirm", a3 == .scheduleEmptyConfirm)
        check("reducer-idle-empty-state", r3.pendingState == .emptyConfirmPending)

        // emptyConfirmPending + non-empty equal to committed = cancel pending, .none, .idle
        let a4 = r3.snapshot([d1], committed: committed)
        check("reducer-emptyconfirm-nonempty-noop", a4 == .none)
        check("reducer-emptyconfirm-nonempty-idle", r3.pendingState == .idle)

        // emptyConfirmPending + empty = re-arm
        var r4 = WallpaperRefreshReducer()
        _ = r4.snapshot([], committed: committed)
        let a5 = r4.snapshot([], committed: committed)
        check("reducer-emptyconfirm-empty-rearm", a5 == .scheduleEmptyConfirm)
        check("reducer-emptyconfirm-empty-state", r4.pendingState == .emptyConfirmPending)

        // emptyConfirmFired with valid gen = commitEmpty
        var r5 = WallpaperRefreshReducer()
        _ = r5.snapshot([], committed: committed)
        let a6 = r5.emptyConfirmFired(capturedGen: 3, currentGen: 3)
        check("reducer-emptyconfirmfired-valid", a6 == .commitEmpty)

        // emptyConfirmFired with stale gen = dropStale
        var r6 = WallpaperRefreshReducer()
        _ = r6.snapshot([], committed: committed)
        let a7 = r6.emptyConfirmFired(capturedGen: 1, currentGen: 2)
        check("reducer-emptyconfirmfired-stale", a7 == .dropStale)

        // debounceFired with valid gen = commit
        var r7 = WallpaperRefreshReducer()
        _ = r7.snapshot([d2], committed: committed)
        let a8 = r7.debounceFired(capturedGen: 5, currentGen: 5)
        check("reducer-debouncefired-valid", a8 == .commit([d2]))

        // debounceFired with stale gen = dropStale
        var r8 = WallpaperRefreshReducer()
        _ = r8.snapshot([d2], committed: committed)
        let a9 = r8.debounceFired(capturedGen: 1, currentGen: 2)
        check("reducer-debouncefired-stale", a9 == .dropStale)

        // debouncePending + new snapshot coalesces (still returns scheduleDebounce)
        var r9 = WallpaperRefreshReducer()
        _ = r9.snapshot([d2], committed: committed)
        let d3 = ScreenDescriptor(displayID: 3, frame: CGRect(x:0, y:0, width:2560, height:1440), scale:2, pixelW:5120, pixelH:2880)
        let a10 = r9.snapshot([d3], committed: committed)
        check("reducer-debounce-coalesce", a10 == .scheduleDebounce)
        if case .debouncePending(let n) = r9.pendingState {
            check("reducer-debounce-latest-wins", n == [d3])
        } else {
            check("reducer-debounce-latest-wins", false)
        }

        // empty then non-empty: emptyConfirm should NEVER fire (commitEmpty must not happen)
        var r10 = WallpaperRefreshReducer()
        _ = r10.snapshot([], committed: committed)
        _ = r10.snapshot([d1], committed: committed)
        let a11 = r10.emptyConfirmFired(capturedGen: 99, currentGen: 99)
        check("reducer-empty-then-nonempty-no-commitEmpty", a11 == .dropStale)

        // debouncePending + committed-equal non-empty = cancel pending, .none, .idle (no-op-during-pending)
        var r11 = WallpaperRefreshReducer()
        _ = r11.snapshot([d2], committed: committed)  // enters debouncePending with next=[d2]
        let a12 = r11.snapshot([d1], committed: committed)  // d1 == committed: should no-op
        check("reducer-debounce-noop-during-pending-action", a12 == .none)
        check("reducer-debounce-noop-during-pending-idle", r11.pendingState == .idle)

        // Sentinel IDs: two screens with missing NSScreenNumber get distinct IDs with the high bit set.
        // Real CGDirectDisplayIDs are small positive integers and do not use the high bit (0x80000000).
        let sentinel0: CGDirectDisplayID = 0x8000_0000 | CGDirectDisplayID(0)
        let sentinel1: CGDirectDisplayID = 0x8000_0000 | CGDirectDisplayID(1)
        check("sentinel-high-bit-set", (sentinel0 & 0x8000_0000) != 0)
        check("sentinel-distinct", sentinel0 != sentinel1)
        let ds0 = ScreenDescriptor(displayID: sentinel0, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let ds1 = ScreenDescriptor(displayID: sentinel1, frame: CGRect(x:1920, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        check("sentinel-arrangement-changed", arrangementChanged(committed: [ds0], next: [ds1]))

        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SELFTEST summary passed=\(passed) failed=\(failed)\n".utf8))
        exit(failed == 0 ? 0 : 1)
    }
}
