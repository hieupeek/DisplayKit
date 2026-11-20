import Foundation
import CoreGraphics
import Combine

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/FreeDisplay/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FreeDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        loadAll()
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "fd.launchAtLogin"
        static let launchAtLoginPrompted  = "fd.launchAtLogin.prompted"
        static let menuWidth              = "fd.menuWidth"
        static let showCombinedBrightness = "fd.showCombinedBrightness"
        static let ddcCacheTTL            = "fd.ddcCacheTTL"
        static let checkUpdatesOnLaunch   = "fd.checkUpdatesOnLaunch"
        static let colorPickerHistory     = "fd.colorPickerHistory"
        static let externalPosition       = "fd.arrangement.externalPosition"
        /// Legacy key from before the position preference existed: a boolean
        /// "external above built-in". Read once for migration, then removed.
        static let legacyExternalAbove    = "fd.arrangement.externalAbove"
        // Per-display keys use prefix + displayID
        static let brightnessPrefix       = "fd.brightness_"
        static let contrastPrefix         = "fd.contrast_"
    }

    // MARK: - Auto-Arrange Position

    /// Where an external display is placed relative to the built-in display
    /// when it is plugged in. `.off` disables auto-arranging entirely.
    enum ExternalPosition: String, CaseIterable, Identifiable {
        case left  = "left"
        case right = "right"
        case above = "above"
        case off   = "off"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .left:  return "Left"
            case .right: return "Right"
            case .above: return "Above"
            case .off:   return "Off"
            }
        }

        /// Positions offered in the Arrangement picker (`.off` is a toggle, not a position).
        static var choosable: [ExternalPosition] { [.left, .right, .above] }
    }

    /// Last non-`.off` position, kept in memory only so turning auto-arrange
    /// back on restores the previous choice instead of resetting to `.left`.
    private(set) var lastNonOffPosition: ExternalPosition = .left

    /// Where externals go on connect. Defaults to `.left` for new installs.
    @Published var externalPosition: ExternalPosition = .left {
        didSet {
            if externalPosition != .off { lastNonOffPosition = externalPosition }
            defaults.set(externalPosition.rawValue, forKey: Keys.externalPosition)
        }
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    @Published var menuWidth: Double = 320 {
        didSet { defaults.set(menuWidth, forKey: Keys.menuWidth) }
    }

    @Published var showCombinedBrightness: Bool = true {
        didSet { defaults.set(showCombinedBrightness, forKey: Keys.showCombinedBrightness) }
    }

    @Published var ddcCacheTTL: Double = 5.0 {
        didSet { defaults.set(ddcCacheTTL, forKey: Keys.ddcCacheTTL) }
    }

    @Published var checkUpdatesOnLaunch: Bool = true {
        didSet { defaults.set(checkUpdatesOnLaunch, forKey: Keys.checkUpdatesOnLaunch) }
    }

    /// Recently sampled colors (hex strings, newest first, max 20).
    @Published var colorPickerHistory: [String] = [] {
        didSet {
            defaults.set(colorPickerHistory, forKey: Keys.colorPickerHistory)
        }
    }

    // MARK: - Per-Display Settings

    func brightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.brightnessPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.brightnessPrefix + "\(displayID)")
    }

    func contrast(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.contrastPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.contrastPrefix + "\(displayID)")
    }

    // MARK: - Color History

    func addColorToHistory(_ hex: String) {
        var history = colorPickerHistory.filter { $0 != hex }
        history.insert(hex, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        colorPickerHistory = history
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[SettingsService] Failed to save \(filename): \(error)")
            #endif
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative SMAppService state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        menuWidth = defaults.object(forKey: Keys.menuWidth) != nil
            ? defaults.double(forKey: Keys.menuWidth) : 320
        showCombinedBrightness = defaults.object(forKey: Keys.showCombinedBrightness) != nil
            ? defaults.bool(forKey: Keys.showCombinedBrightness) : true
        ddcCacheTTL = defaults.object(forKey: Keys.ddcCacheTTL) != nil
            ? defaults.double(forKey: Keys.ddcCacheTTL) : 5.0
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkUpdatesOnLaunch) : true
        colorPickerHistory = defaults.stringArray(forKey: Keys.colorPickerHistory) ?? []
        externalPosition = Self.resolveExternalPosition(defaults: defaults)
    }

    /// Resolves the auto-arrange position: the new key wins; otherwise migrate
    /// the legacy `fd.arrangement.externalAbove` boolean (`true` = above,
    /// `false` = off) and delete it; otherwise default to `.left`.
    private static func resolveExternalPosition(defaults: UserDefaults) -> ExternalPosition {
        if let raw = defaults.string(forKey: Keys.externalPosition),
           let pos = ExternalPosition(rawValue: raw) {
            return pos
        }
        if defaults.object(forKey: Keys.legacyExternalAbove) != nil {
            let pos: ExternalPosition = defaults.bool(forKey: Keys.legacyExternalAbove) ? .above : .off
            defaults.set(pos.rawValue, forKey: Keys.externalPosition)
            defaults.removeObject(forKey: Keys.legacyExternalAbove)
            return pos
        }
        return .left
    }
}
