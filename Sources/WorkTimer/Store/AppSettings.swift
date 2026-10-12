import Carbon.HIToolbox
import Foundation

/// User preferences, backed by UserDefaults.
final class AppSettings: ObservableObject {
    static let idleMinutesRange = 1...120

    private let defaults = UserDefaults.standard

    /// Clock in automatically when activity resumes. Turn off for personal time.
    @Published var autoClockIn: Bool {
        didSet { defaults.set(autoClockIn, forKey: Keys.autoClockIn) }
    }

    /// Clock out when the Mac has been idle for `idleMinutes`.
    @Published var autoClockOut: Bool {
        didSet { defaults.set(autoClockOut, forKey: Keys.autoClockOut) }
    }

    @Published var idleMinutes: Int {
        didSet {
            let clamped = min(max(idleMinutes, Self.idleMinutesRange.lowerBound), Self.idleMinutesRange.upperBound)
            if clamped != idleMinutes { idleMinutes = clamped; return }
            defaults.set(idleMinutes, forKey: Keys.idleMinutes)
        }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    @Published var showSecondsInMenuBar: Bool {
        didSet { defaults.set(showSecondsInMenuBar, forKey: Keys.showSeconds) }
    }

    @Published var togglePanelShortcut: KeyCombo? {
        didSet { store(togglePanelShortcut, forKey: Keys.panelShortcut) }
    }

    @Published var toggleTimerShortcut: KeyCombo? {
        didSet { store(toggleTimerShortcut, forKey: Keys.timerShortcut) }
    }

    /// Shortcuts that another app already owns. Not persisted.
    @Published var conflictingShortcuts: Set<HotKeyManager.Action> = []

    var idleThreshold: TimeInterval { TimeInterval(idleMinutes * 60) }

    init() {
        defaults.register(defaults: [
            Keys.autoClockIn: true,
            Keys.autoClockOut: true,
            Keys.idleMinutes: 10,
            Keys.notifications: true,
            Keys.showSeconds: true,
        ])
        autoClockIn = defaults.bool(forKey: Keys.autoClockIn)
        autoClockOut = defaults.bool(forKey: Keys.autoClockOut)
        idleMinutes = defaults.integer(forKey: Keys.idleMinutes)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        showSecondsInMenuBar = defaults.bool(forKey: Keys.showSeconds)
        togglePanelShortcut = Self.loadShortcut(Keys.panelShortcut, default: KeyCombo(
            keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), key: "T"
        ))
        toggleTimerShortcut = Self.loadShortcut(Keys.timerShortcut, default: KeyCombo(
            keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), key: "S"
        ))
    }

    // A missing key means "use the default"; empty data means the user cleared it.
    private static func loadShortcut(_ key: String, default fallback: KeyCombo) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func store(_ combo: KeyCombo?, forKey key: String) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    private enum Keys {
        static let autoClockIn = "autoClockIn"
        static let autoClockOut = "autoClockOut"
        static let idleMinutes = "idleMinutes"
        static let notifications = "notificationsEnabled"
        static let showSeconds = "showSecondsInMenuBar"
        static let panelShortcut = "togglePanelShortcut"
        static let timerShortcut = "toggleTimerShortcut"
    }
}
