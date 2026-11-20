import Foundation
import CoreGraphics

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    /// Moves the given display to the specified position in the global coordinate space.
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayOrigin(cfg, displayID, Int32(x), Int32(y))
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    /// Moves several displays in ONE Begin→Origin→Complete transaction, so the
    /// whole layout changes atomically instead of one transaction per display
    /// (separate transactions can fight each other mid-layout).
    /// The entire transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setPositions(_ positions: [(id: CGDirectDisplayID, x: Int, y: Int)]) async -> Bool {
        guard !positions.isEmpty else { return true }
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for pos in positions {
                CGConfigureDisplayOrigin(cfg, pos.id, Int32(pos.x), Int32(pos.y))
            }
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    /// Makes the target display the main display by moving it to origin (0, 0).
    /// Moves the current main display to the position previously occupied by the target.
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID, among displays: [DisplayInfo]) async -> Bool {
        guard let target = displays.first(where: { $0.displayID == targetID }),
              let currentMain = displays.first(where: { $0.isMain }),
              currentMain.displayID != targetID else {
            return false
        }

        // Capture value types only — no OpaquePointer crossing the @Sendable boundary.
        let targetOriginX = Int32(target.bounds.origin.x)
        let targetOriginY = Int32(target.bounds.origin.y)
        let currentMainID = currentMain.displayID

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            // Move target to origin → it becomes the new main display
            CGConfigureDisplayOrigin(cfg, targetID, 0, 0)

            // Move old main to where the target was.
            CGConfigureDisplayOrigin(cfg, currentMainID, targetOriginX, targetOriginY)

            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
