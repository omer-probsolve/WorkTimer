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
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text(Format.duration(max(0, effectiveEnd.timeIntervalSince(start))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", action: onDone)
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(error != nil)
                }
                .controlSize(.small)
            }
        }
        .datePickerStyle(.stepperField)
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Export CSV").font(.headline)
                Spacer()
                presetsMenu
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .day:
                DatePicker("Date", selection: $day, displayedComponents: .date)
            case .range:
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            case .all:
                Text("Every session you've logged.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(summary.count) session\(summary.count == 1 ? "" : "s") · \(Format.duration(summary.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Export…", action: export)
                    .buttonStyle(.borderedProminent)
                    .disabled(summary.count == 0)
            }
        }
        .datePickerStyle(.stepperField)
        .padding(10)
        .cardBackground()
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
        Form {
            Section("Automatic tracking") {
                Toggle("Clock in when I'm active", isOn: $settings.autoClockIn)
                Toggle("Clock out when the Mac is idle", isOn: $settings.autoClockOut)
                Stepper(value: $settings.idleMinutes, in: AppSettings.idleMinutesRange) {
                    Text("Idle after \(settings.idleMinutes) min")
                        .monospacedDigit()
                }
                .disabled(!settings.autoClockOut)
                Text("Idle time isn't counted: the session ends when your last activity was. A clock-out notification lets you add it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify on automatic clock-in / out", isOn: $settings.notificationsEnabled)
                if notificationsDenied {
                    HStack(spacing: 6) {
                        Text("Notifications are blocked in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open…") { Notifier.openSystemSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            Section("Keyboard shortcuts") {
                LabeledContent("Show / hide window") {
                    ShortcutRecorder(combo: $settings.togglePanelShortcut)
                }
                LabeledContent("Start / stop timer") {
                    ShortcutRecorder(combo: $settings.toggleTimerShortcut)
                }
                if !settings.conflictingShortcuts.isEmpty {
                    Text("A shortcut is already used by another app — pick a different one.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Timeline") {
                DatePicker("Starts", selection: minuteBinding(\.timelineStartMinute), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: minuteBinding(\.timelineEndMinute), displayedComponents: .hourAndMinute)
                Text("The hours the day timelines show, in the menu bar window and the dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show seconds in the menu bar", isOn: $settings.showSecondsInMenuBar)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Show Data File") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.dataFileURL])
                    }
                    Spacer()
                    Button("Quit Work Timer") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            Notifier().authorizationDenied { notificationsDenied = $0 }
        }
    }

    /// Edits a minutes-after-midnight setting as a time of day.
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
