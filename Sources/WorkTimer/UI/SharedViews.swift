import AppKit
import SwiftUI
import WorkTimerCore

struct SessionEditor: View {
    enum Target {
        case running(ActiveSession)
        case finished(WorkSession)
    }

    let store: SessionStore
    let target: Target
    let onDone: () -> Void

    @State private var start: Date
    @State private var end: Date

    init(store: SessionStore, target: Target, onDone: @escaping () -> Void) {
        self.store = store
        self.target = target
        self.onDone = onDone
        switch target {
        case let .running(active):
            _start = State(initialValue: active.start)
            _end = State(initialValue: Date())
        case let .finished(session):
            _start = State(initialValue: session.start)
            _end = State(initialValue: session.end)
        }
    }

    private var isRunning: Bool {
        if case .running = target { return true }
        return false
    }

    var body: some View {
        // Re-validate every second so "now" (the running session's end) stays current.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let effectiveEnd = isRunning ? context.date : end
            let error = validate(end: effectiveEnd, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                if isRunning {
                    LabeledContent("End", value: "Now (running)")
                } else {
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                }
                if let error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(IslandTheme.warning)
                }
                HStack {
                    Text(Format.duration(max(0, effectiveEnd.timeIntervalSince(start))))
                        .font(.caption)
                        .foregroundStyle(IslandTheme.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", action: onDone)
                        .buttonStyle(IslandButtonStyle(height: 26))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .buttonStyle(IslandButtonStyle(primary: true, height: 26))
                        .keyboardShortcut(.defaultAction)
                        .disabled(error != nil)
                }
                .padding(.top, 2)
            }
        }
        .datePickerStyle(.stepperField)
        .font(.callout)
        .islandCard(padding: 12)
    }

    private func validate(end: Date, now: Date) -> SessionLog.EditError? {
        switch target {
        case .running: return store.validateEdit(id: nil, start: start, end: now, now: now)
        case let .finished(session): return store.validateEdit(id: session.id, start: start, end: end, now: now)
        }
    }

    private func save() {
        switch target {
        case .running: store.updateActiveStart(start)
        case let .finished(session): store.update(session.id, start: start, end: end)
        }
        onDone()
    }
}

/// Picks what to export — one day, a date range, or everything — then saves a CSV.
struct ExportBox: View {
    @ObservedObject var store: SessionStore
    let onClose: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case day = "Day", range = "Range", all = "All"
        var id: Self { self }
    }

    @State private var mode: Mode = .day
    @State private var day = Date()
    @State private var from = DateInterval.of(.weekOfYear, containing: Date()).start
    @State private var to = Date()

    private let calendar = Calendar.current

    /// nil means every session.
    private var interval: DateInterval? {
        switch mode {
        case .all:
            return nil
        case .day:
            return .of(.day, containing: day)
        case .range:
            let start = calendar.startOfDay(for: min(from, to))
            let end = DateInterval.of(.day, containing: max(from, to)).end
            return DateInterval(start: start, end: end)
        }
    }

    private var summary: (count: Int, total: TimeInterval) {
        guard let interval else {
            return (store.sessions.count, store.sessions.reduce(0) { $0 + $1.duration })
        }
        let sessions = store.sessions(in: interval)
        return (sessions.count, sessions.reduce(0) { $0 + $1.overlap(with: interval) })
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IslandLabel("Export CSV")
                Spacer()
                presetsMenu
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IslandTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            IslandSegmented(Mode.allCases.map { ($0, $0.rawValue) }, selection: $mode)
                .fixedSize()

            switch mode {
            case .day:
                DatePicker("Date", selection: $day, displayedComponents: .date)
            case .range:
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            case .all:
                Text("Every session you've logged.")
                    .foregroundStyle(IslandTheme.secondary)
            }

            HStack {
                Text("\(summary.count) session\(summary.count == 1 ? "" : "s") · \(Format.duration(summary.total))")
                    .font(.caption)
                    .foregroundStyle(IslandTheme.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Export…", action: export)
                    .buttonStyle(IslandButtonStyle(primary: true, height: 26))
                    .disabled(summary.count == 0)
            }
        }
        .datePickerStyle(.stepperField)
        .islandCard(padding: 12)
    }

    private var presetsMenu: some View {
        Menu("Presets") {
            Button("Today") { pickDay(Date()) }
            Button("Yesterday") { pickDay(calendar.date(byAdding: .day, value: -1, to: Date())!) }
            Divider()
            Button("This week") { pickRange(.weekOfYear, offset: 0) }
            Button("Last week") { pickRange(.weekOfYear, offset: -1) }
            Button("This month") { pickRange(.month, offset: 0) }
            Button("Last month") { pickRange(.month, offset: -1) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func pickDay(_ date: Date) {
        mode = .day
        day = date
    }

    private func pickRange(_ component: Calendar.Component, offset: Int) {
        let reference = calendar.date(byAdding: component, value: offset, to: Date())!
        let period = DateInterval.of(component, containing: reference)
        mode = .range
        from = period.start
        // The period's end is midnight of the next day; step back into the last day.
        to = min(period.end.addingTimeInterval(-1), Date())
    }

    private var fileName: String {
        switch mode {
        case .all: return "work-time-all.csv"
        case .day: return "work-time-\(Format.isoDay(day)).csv"
        case .range:
            let lo = Format.isoDay(min(from, to)), hi = Format.isoDay(max(from, to))
            return lo == hi ? "work-time-\(lo).csv" : "work-time-\(lo)-to-\(hi).csv"
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.csv(in: interval).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: SessionStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemError: String?
    @State private var notificationsDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IslandSection(
                    "Automatic tracking",
                    footer: "Idle time isn't counted: the session ends when your last activity was. A clock-out notification lets you add it back."
                ) {
                    IslandToggleRow("Clock in when I'm active", isOn: $settings.autoClockIn)
                    IslandDivider()
                    IslandToggleRow("Clock out when the Mac is idle", isOn: $settings.autoClockOut)
                    IslandDivider()
                    IslandSettingRow("Idle after \(settings.idleMinutes) min") {
                        Stepper("Idle after", value: $settings.idleMinutes, in: AppSettings.idleMinutesRange)
                            .labelsHidden()
                    }
                    .monospacedDigit()
                    .disabled(!settings.autoClockOut)
                    .opacity(settings.autoClockOut ? 1 : 0.4)
                }

                IslandSection("Notifications") {
                    IslandToggleRow("Notify on automatic clock-in / out", isOn: $settings.notificationsEnabled)
                    if notificationsDenied {
                        HStack(spacing: 6) {
                            warning("Notifications are blocked in System Settings.")
                            Button("Open…") { Notifier.openSystemSettings() }
                                .buttonStyle(IslandLinkButtonStyle())
                        }
                    }
                }

                IslandSection("Keyboard shortcuts") {
                    IslandSettingRow("Show / hide window") {
                        ShortcutRecorder(combo: $settings.togglePanelShortcut)
                    }
                    IslandDivider()
                    IslandSettingRow("Start / stop timer") {
                        ShortcutRecorder(combo: $settings.toggleTimerShortcut)
                    }
                    if !settings.conflictingShortcuts.isEmpty {
                        warning("A shortcut is already used by another app — pick a different one.")
                    }
                }

                IslandSection(
                    "AI World",
                    footer: "Reads the agent turns of AI World running on this Mac, from its local database. Nothing in AI World is changed. Work Timer asks the Supabase CLI (supabase status) in this folder for the database's key."
                ) {
                    IslandToggleRow("Count AI World agents", isOn: $settings.countAIWorld)
                    IslandDivider()
                    IslandSettingRow("AI World folder") {
                        Text(settings.aiWorldFolder.isEmpty ? "Not set" : (settings.aiWorldFolder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12))
                            .foregroundStyle(IslandTheme.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseAIWorldFolder() }
                            .buttonStyle(IslandButtonStyle(height: 26))
                    }
                }

                IslandSection(
                    "Timeline",
                    footer: "The hours the day timelines show, in the menu bar window and the dashboard."
                ) {
                    IslandSettingRow("Starts") {
                        DatePicker("Starts", selection: minuteBinding(\.timelineStartMinute), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    IslandDivider()
                    IslandSettingRow("Ends") {
                        DatePicker("Ends", selection: minuteBinding(\.timelineEndMinute), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                .datePickerStyle(.stepperField)

                IslandSection("General") {
                    IslandToggleRow("Show seconds in the menu bar", isOn: $settings.showSecondsInMenuBar)
                    IslandDivider()
                    IslandToggleRow("Show only the icon on screens with a notch", isOn: $settings.iconOnlyOnNotchedScreens)
                        .help("macOS hides menu bar items that don't fit beside the notch.")
                    // A host (Toolbelt) owns the login item and quitting.
                    if !Host.isHosted {
                        IslandDivider()
                        IslandToggleRow("Open at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                        if let loginItemError {
                            warning(loginItemError)
                        }
                    }
                    IslandDivider()
                    HStack {
                        Button("Show Data File") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.dataFileURL])
                        }
                        Spacer()
                        if !Host.isHosted {
                            Button("Quit Work Timer") { NSApp.terminate(nil) }
                        }
                    }
                    .buttonStyle(IslandButtonStyle(height: 26))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(IslandTheme.accent)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            Notifier().authorizationDenied { notificationsDenied = $0 }
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(IslandTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Edits a minutes-after-midnight setting as a time of day.
    private func chooseAIWorldFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose AI World's project folder, the one with supabase/config.toml."
        if !settings.aiWorldFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.aiWorldFolder) }
        if panel.runModal() == .OK, let url = panel.url { settings.aiWorldFolder = url.path }
    }

    private func minuteBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Binding(
            get: { midnight.addingTimeInterval(TimeInterval(settings[keyPath: keyPath] * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update the login item: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
