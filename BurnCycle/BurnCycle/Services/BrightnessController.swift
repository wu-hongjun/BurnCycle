import Foundation
import CoreGraphics
import AppKit

/// Wraps macOS's private `DisplayServicesGet/SetBrightness` so the cycle engine
/// can dim the screen while charging (reducing screen-draw to charge slightly
/// faster) and restore the user's pre-cycle brightness on drain.
///
/// Brightness control on macOS has no public API. `DisplayServices` is a private
/// system framework, but the two symbols below are stable across recent macOS
/// releases and are what every brightness-control tool uses (matches the same
/// "private but stable" trade-off already accepted for IOReport in
/// `SystemMonitor`). Loaded lazily via `dlopen`; if either symbol can't be
/// resolved we fall back to "unavailable" and the UI hides the feature.
///
/// Concurrency: stays on the main actor — brightness writes are cheap and
/// triggered from main-actor code (CycleEngine transitions / settings observer).
@MainActor
final class BrightnessController: ObservableObject {
    /// Surface-able diagnostic. UI may show this when `isAvailable` is false
    /// or when a set/get call returns a non-zero status.
    @Published var lastError: String?

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: GetFn?
    private let setFn: SetFn?

    /// The brightness we observed just before the first dim of the current
    /// charge phase. Restored on drain / stop / setting-off. nil when we are
    /// not currently managing brightness.
    private var savedBrightness: Float?

    /// Restores brightness on app quit so a crash-during-charge or a forced
    /// terminate doesn't leave the screen pinned dim.
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            self.getFn = nil
            self.setFn = nil
            self.lastError = "DisplayServices.framework unavailable"
            return
        }

        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            self.getFn = unsafeBitCast(sym, to: GetFn.self)
        } else {
            self.getFn = nil
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            self.setFn = unsafeBitCast(sym, to: SetFn.self)
        } else {
            self.setFn = nil
        }
        if getFn == nil || setFn == nil {
            self.lastError = "DisplayServices brightness symbols missing"
        }

        // Best-effort restore on app quit so a forced-terminate or graceful
        // ⌘Q during a charge phase doesn't leave the screen pinned dim.
        let nc = NotificationCenter.default
        terminationObserver = nc.addObserver(forName: NSApplication.willTerminateNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restore() }
        }
    }

    deinit {
        // NotificationCenter retains the block independently of the token;
        // explicitly remove or it can fire against a dead object.
        if let token = terminationObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// True when both required symbols resolved. The UI should hide / disable
    /// dim-while-charging affordances when this is false.
    var isAvailable: Bool { getFn != nil && setFn != nil }

    /// True when we're currently holding a saved brightness value (i.e. the
    /// engine asked us to dim and we haven't restored yet).
    var isDimming: Bool { savedBrightness != nil }

    /// Read the current brightness of the main display (0...1). nil on failure.
    func current() -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        let err = getFn(CGMainDisplayID(), &value)
        if err != 0 {
            lastError = "Read brightness failed (\(err))"
            return nil
        }
        return value
    }

    /// Set brightness on the main display. Clamps to 0...1. Returns true on success.
    @discardableResult
    func set(_ value: Float) -> Bool {
        guard let setFn else { return false }
        let clamped = max(0, min(1, value))
        let err = setFn(CGMainDisplayID(), clamped)
        if err != 0 {
            lastError = "Set brightness failed (\(err))"
            return false
        }
        // Successful write — clear any prior diagnostic.
        if lastError != nil { lastError = nil }
        return true
    }

    /// Save the user's current brightness (only on the first call of a dim
    /// session — subsequent calls just re-apply the target without overwriting
    /// the saved value), then dim to `target`. The save-once rule is important:
    /// if the engine retargets during a charge phase (settings slider moved),
    /// we don't want to overwrite the pre-charge baseline with our own dim.
    func saveAndDim(to target: Float) {
        if savedBrightness == nil, let now = current() {
            savedBrightness = now
        }
        _ = set(target)
    }

    /// Restore the most recently saved brightness, if any. Idempotent.
    func restore() {
        guard let saved = savedBrightness else { return }
        _ = set(saved)
        savedBrightness = nil
    }
}
