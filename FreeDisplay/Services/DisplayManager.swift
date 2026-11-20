import Foundation
import CoreGraphics

// Global C-compatible callback for display reconfiguration.
// Must be a top-level function (not a closure) to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()

    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setMainFlag, .setModeFlag]
    guard !flags.intersection(relevant).isEmpty else { return }

    // Skip the begin-configuration notification; only act when the change is complete.
    // (beginConfigurationFlag is set at the start of a transaction; absence means it finished.)
    guard !flags.contains(.beginConfigurationFlag) else { return }

    Task { @MainActor in
        if flags.intersection([.addFlag, .removeFlag]).isEmpty {
            // Mode or main-display change: refresh mode info for existing displays only.
            manager.refreshExistingDisplayModes()
        } else {
            manager.refreshDisplays()
        }

        // Auto-rearrange after any display config change completes (debounced 500 ms).
        manager.scheduleAutoArrange()
    }
}

@MainActor
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?

    /// Work item used to debounce auto-arrange calls triggered by display config changes.
    private var autoArrangeWorkItem: DispatchWorkItem?

    /// Display IDs the last auto-arrange was applied to. Auto-arrange only runs
    /// when this set changes (a display was plugged in or unplugged) — a manual
    /// drag in System Settings or ArrangementView leaves the set unchanged, so
    /// it is never fought by a re-apply. `force: true` (preference change,
    /// first launch) bypasses this guard.
    private var lastAutoArrangedDisplayIDs: Set<CGDirectDisplayID> = []

    init() {
        refreshDisplays()
        setupReconfigCallback()
    }

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
            Unmanaged<DisplayManager>.fromOpaque(ctx).release()
        }
    }

    func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })

        // Clean up DDC cache for removed displays to prevent stale entries accumulating
        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
        }

        // Diff-based refresh: keep existing DisplayInfo objects (preserves @Published state)
        var existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if let existing = existingByID[id] {
                updatedDisplays.append(existing)
            } else {
                let info = DisplayInfo(displayID: id)
                updatedDisplays.append(info)
                addedDisplays.append(info)
            }
        }

        displays = updatedDisplays
        DisplayManagerAccessor.shared.displays = updatedDisplays

        // Regenerate built-in presets (HiDPI mode / Native mode) from updated display list.
        PresetService.shared.refreshBuiltins()

        // Only load details / refresh brightness for newly appeared displays
        for display in addedDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
            Task {
                await display.loadDetails()
                // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
                PresetService.shared.refreshBuiltins()
            }
            // Restore saved gamma/software-brightness adjustments for the reconnected display.
            // Brief delay lets WindowServer settle before we write transfer tables.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display.displayID)
            }
        }

        // For displays that were already present, only update bounds/main flag (no DDC probe).
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            display.bounds = CGDisplayBounds(display.displayID)
            display.isMain = CGDisplayIsMain(display.displayID) != 0
        }
    }

    /// Auto-enables HiDPI plist override for external 2K+ displays that don't have it yet.
    /// This ensures switching between different monitors "just works" without manual re-enable.
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        // Already enabled — nothing to do
        guard !HiDPIService.shared.isHiDPIEnabled(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        print("[DisplayManager] Auto-enabling HiDPI for \(display.name) (\(nativeW)×\(nativeH), vendor=\(vendor), product=\(product))")

        let err = await HiDPIService.shared.enableHiDPI(
            for: display.displayID,
            vendor: vendor,
            product: product,
            nativeWidth: nativeW,
            nativeHeight: nativeH
        )

        if let err {
            print("[DisplayManager] Auto-enable HiDPI failed: \(err)")
        } else {
            print("[DisplayManager] Auto-enable HiDPI succeeded, refreshing modes")
            HiDPIService.shared.refreshModes(for: display)
            // Give IOServiceRequestProbe time to re-enumerate modes
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await display.loadDetails()
            PresetService.shared.refreshBuiltins()
        }
    }

    /// Debounces calls to `arrangeExternalDisplay()` — coalesces bursts of config-change
    /// callbacks into a single rearrange that fires 500 ms after the last callback arrives.
    func scheduleAutoArrange() {
        autoArrangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.arrangeExternalDisplay()
        }
        autoArrangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func setupReconfigCallback() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackContext = ctx
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)
    }

    /// Refreshes mode info and main-display flag for already-tracked displays
    /// (for setModeFlag / setMainFlag events).
    /// Cheaper than a full `refreshDisplays()` — does not add/remove DisplayInfo objects.
    func refreshExistingDisplayModes() {
        for display in displays {
            // Always refresh isMain synchronously since it's cheap and needed for setMainFlag events.
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: display.displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Toggle a display on/off.
    /// NOTE: macOS has no public API for enabling/disabling individual displays
    /// (CGConfigureDisplayEnabled is private). This function always returns false
    /// to signal to callers that the operation is not supported.
    @discardableResult
    func toggleDisplay(_ display: DisplayInfo) -> Bool {
        // No-op: cannot enable/disable displays via public API
        return false
    }

    /// Makes the target display the main display by repositioning it to origin (0, 0).
    func setAsMainDisplay(_ display: DisplayInfo) {
        Task { @MainActor in
            let ok = await ArrangementService.shared.setAsMainDisplay(display.displayID, among: self.displays)
            if ok { self.refreshDisplays() }
        }
    }

    /// Positions external displays relative to the built-in display when one is
    /// plugged in, per `SettingsService.externalPosition` (`fd.arrangement.externalPosition`):
    /// `.left` (default) — externals stacked left-to-right at (0, 0), built-in to
    /// their right, top-aligned; the external at the origin becomes the main display.
    /// `.right` — built-in at (0, 0), externals stacked to its right, top-aligned.
    /// `.above` — each external centered above the built-in (previous behaviour).
    /// `.off` — does nothing.
    /// Does nothing if there is no built-in display or no external displays.
    /// Runs only when the online display set changed since the last auto-arrange
    /// (so a manual drag is left alone), unless `force` is true, and skips when
    /// the current origins already match the target within 1 px (so our own
    /// reconfiguration callback cannot loop).
    func arrangeExternalDisplay(force: Bool = false) {
        let position = SettingsService.shared.externalPosition
        guard position != .off else { return }

        guard let builtin = displays.first(where: { $0.isBuiltin }) else { return }
        let externals = displays.filter { !$0.isBuiltin }
        guard !externals.isEmpty else { return }

        let currentIDs = Set(displays.map { $0.displayID })
        if !force, currentIDs == lastAutoArrangedDisplayIDs { return }

        let targets = Self.arrangementTargets(
            position: position, builtin: builtin, externals: externals
        )
        let alreadyThere = targets.allSatisfy { target in
            displays.contains {
                $0.displayID == target.id
                && abs(Int($0.bounds.origin.x) - target.x) <= 1
                && abs(Int($0.bounds.origin.y) - target.y) <= 1
            }
        }
        if alreadyThere {
            lastAutoArrangedDisplayIDs = currentIDs
            return
        }

        Task { @MainActor in
            let ok = await ArrangementService.shared.setPositions(targets)
            if ok {
                self.lastAutoArrangedDisplayIDs = currentIDs
                self.refreshDisplays()
            }
        }
    }

    /// Pure layout maths for `arrangeExternalDisplay()` (no side effects, so the
    /// positions are unit-checkable). Sizes are logical points from `bounds`.
    /// - left: externals in displayID order from x = 0, built-in after the last one.
    /// - right: built-in at (0, 0), externals after it in displayID order.
    /// - above: each external centered horizontally above the built-in.
    /// - off: no targets (callers guard this, but returns [] for safety).
    static func arrangementTargets(
        position: SettingsService.ExternalPosition,
        builtin: DisplayInfo,
        externals: [DisplayInfo]
    ) -> [(id: CGDirectDisplayID, x: Int, y: Int)] {
        let sortedExternals = externals.sorted { $0.displayID < $1.displayID }
        switch position {
        case .off:
            return []
        case .above:
            let builtinX = Int(builtin.bounds.origin.x)
            let builtinY = Int(builtin.bounds.origin.y)
            let builtinWidth = Int(builtin.bounds.width)
            return sortedExternals.map { ext in
                let extWidth = Int(ext.bounds.width)
                let centeredX = builtinX + (builtinWidth - extWidth) / 2
                return (id: ext.displayID, x: centeredX, y: builtinY - Int(ext.bounds.height))
            }
        case .left:
            var targets: [(id: CGDirectDisplayID, x: Int, y: Int)] = []
            var x = 0
            for ext in sortedExternals {
                targets.append((id: ext.displayID, x: x, y: 0))
                x += Int(ext.bounds.width)
            }
            targets.append((id: builtin.displayID, x: x, y: 0))
            return targets
        case .right:
            var targets: [(id: CGDirectDisplayID, x: Int, y: Int)] = []
            targets.append((id: builtin.displayID, x: 0, y: 0))
            var x = Int(builtin.bounds.width)
            for ext in sortedExternals {
                targets.append((id: ext.displayID, x: x, y: 0))
                x += Int(ext.bounds.width)
            }
            return targets
        }
    }
}
