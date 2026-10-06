import Foundation
import CoreGraphics

struct ScreenDescriptor: Equatable, Hashable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let pixelW: Int
    let pixelH: Int
}

func arrangementChanged(committed: [ScreenDescriptor], next: [ScreenDescriptor]) -> Bool {
    return Set(committed) != Set(next)
}

enum RefreshAction: Equatable {
    case none
    case scheduleDebounce
    case scheduleEmptyConfirm
    case commit([ScreenDescriptor])
    case commitEmpty
    case dropStale
}

struct WallpaperRefreshReducer {
    enum PendingState: Equatable {
        case idle
        case debouncePending(next: [ScreenDescriptor])
        case emptyConfirmPending
    }

    var pendingState: PendingState = .idle

    mutating func snapshot(_ next: [ScreenDescriptor], committed: [ScreenDescriptor]) -> RefreshAction {
        switch pendingState {
        case .idle:
            if next.isEmpty {
                pendingState = .emptyConfirmPending
                return .scheduleEmptyConfirm
            }
            if !arrangementChanged(committed: committed, next: next) {
                return .none
            }
            pendingState = .debouncePending(next: next)
            return .scheduleDebounce

        case .debouncePending:
            if next.isEmpty {
                pendingState = .emptyConfirmPending
                return .scheduleEmptyConfirm
            }
            if !arrangementChanged(committed: committed, next: next) {
                pendingState = .idle
                return .none
            }
            pendingState = .debouncePending(next: next)
            return .scheduleDebounce

        case .emptyConfirmPending:
            if next.isEmpty {
                return .scheduleEmptyConfirm
            }
            if !arrangementChanged(committed: committed, next: next) {
                pendingState = .idle
                return .none
            }
            pendingState = .debouncePending(next: next)
            return .scheduleDebounce
        }
    }

    mutating func debounceFired(capturedGen: Int, currentGen: Int) -> RefreshAction {
        guard capturedGen == currentGen else { return .dropStale }
        guard case .debouncePending(let next) = pendingState else { return .dropStale }
        pendingState = .idle
        return .commit(next)
    }

    mutating func emptyConfirmFired(capturedGen: Int, currentGen: Int) -> RefreshAction {
        guard capturedGen == currentGen else { return .dropStale }
        guard case .emptyConfirmPending = pendingState else { return .dropStale }
        pendingState = .idle
        return .commitEmpty
    }
}
