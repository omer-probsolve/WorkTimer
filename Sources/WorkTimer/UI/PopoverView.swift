import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    let tracker: TimeTracker

    enum Tab: String, CaseIterable, Identifiable {
        case timer = "Timer", history = "History", settings = "Settings"
        var id: Self { self }
    }

    @State private var tab: Tab = .timer

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .timer: TimerTab(store: store, settings: settings, tracker: tracker)
                case .history: HistoryTab(store: store)
                case .settings: SettingsTab(settings: settings, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 340, height: 520)
    }
}

// MARK: - Timer

private struct TimerTab: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    let tracker: TimeTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: 14) {
                header(now: now)
                startStopButton
                autoTrackingCard
                totals(now: now)
                todayList(now: now)
            }
            .padding(14)
        }
    }

    private func header(now: Date) -> some View {
        VStack(spacing: 4) {
            Text(Format.clock(store.elapsed(now: now)))
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(store.isRunning ? .primary : .secondary)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var statusLine: String {
        guard let active = store.active else {
            return settings.autoClockIn ? "Not tracking — will clock in when you're active" : "Not tracking — auto clock-in is off"
        }
        return "Working since \(Format.time(active.start))" + (active.startedAutomatically ? " · started automatically" : "")
    }

    private var startStopButton: some View {
        Button(action: tracker.toggle) {
            Label(store.isRunning ? "Stop Working" : "Start Working",
                  systemImage: store.isRunning ? "stop.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(store.isRunning ? .red : .green)
        .controlSize(.large)
    }

    private var autoTrackingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $settings.autoClockIn) {
                Text("Auto clock-in").font(.body.weight(.medium))
            }
            .toggleStyle(.switch)
            Text(settings.autoClockIn
                 ? "Starts when you're active on the Mac. Turn off when doing personal stuff."
                 : "Off — you're on your own time. Start the timer manually if you need it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func totals(now: Date) -> some View {
        let calendar = Calendar.current
        let today = calendar.dateInterval(of: .day, for: now)!
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        return HStack(spacing: 10) {
            StatTile(title: "Today", value: Format.duration(store.total(in: today, now: now)))
            StatTile(title: "This week", value: Format.duration(store.total(in: week, now: now)))
        }
    }

    private func todayList(now: Date) -> some View {
        let today = Calendar.current.dateInterval(of: .day, for: now)!
        let sessions = store.sessions(in: today).reversed()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Today's sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    if let active = store.active {
                        EditableSessionRow(store: store, target: .running(active), now: now)
                            .id(active.id)
                    }
                    ForEach(Array(sessions)) { session in
                        EditableSessionRow(store: store, target: .finished(session), now: now)
                    }
                    if store.active == nil && sessions.isEmpty {
                        Text("Nothing logged yet today.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct SessionRow: View {
    let start: Date
    let end: Date?
    let duration: TimeInterval
    let automatic: Bool
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(end == nil ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text("\(Format.time(start)) – \(end.map(Format.time) ?? "now")")
                .monospacedDigit()
            if automatic {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Started automatically")
            }
            Spacer()
            Text(Format.duration(duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help(end == nil ? "Edit start time" : "Edit times")
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Delete session")
            } else {
                // Reserve the trash button's space so durations stay aligned across rows.
                Button(action: {}) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button(end == nil ? "Edit Start Time…" : "Edit Times…", action: onEdit)
            if let onDelete {
                Button("Delete Session", role: .destructive, action: onDelete)
            }
        }
    }
}

/// A session row that turns into an inline editor.
private struct EditableSessionRow: View {
    @ObservedObject var store: SessionStore
    let target: SessionEditor.Target
    let now: Date

    @State private var editing = false

    var body: some View {
        if editing {
            SessionEditor(store: store, target: target, onDone: { editing = false })
        } else {
            switch target {
            case let .running(active):
                SessionRow(
                    start: active.start, end: nil, duration: max(0, now.timeIntervalSince(active.start)),
                    automatic: active.startedAutomatically,
                    onEdit: { editing = true }, onDelete: nil
                )
            case let .finished(session):
                SessionRow(
                    start: session.start, end: session.end, duration: session.duration,
                    automatic: session.startedAutomatically,
                    onEdit: { editing = true }, onDelete: { store.delete(session.id) }
                )
            }
        }
    }
}

private struct SessionEditor: View {
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

    private func validate(end: Date, now: Date) -> SessionStore.EditError? {
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

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var store: SessionStore

    @State private var showExport = false

    private struct Day: Identifiable {
        let date: Date
        let sessions: [WorkSession]
        var id: Date { date }
        var total: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.sessions) { calendar.startOfDay(for: $0.start) }
        return grouped
            .map { Day(date: $0.key, sessions: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.sessions.count) sessions logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…") { showExport.toggle() }
                    .controlSize(.small)
                    .disabled(store.sessions.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if showExport {
                ExportBox(store: store, onClose: { showExport = false })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if days.isEmpty {
                Spacer()
                Text("No finished sessions yet.")
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                List {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.sessions) { session in
                                EditableSessionRow(store: store, target: .finished(session), now: Date())
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                            }
                        } header: {
                            HStack {
                                Text(Format.day(day.date))
                                Spacer()
                                Text(Format.duration(day.total)).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

}

/// Picks what to export — one day, a date range, or everything — then saves a CSV.
private struct ExportBox: View {
    @ObservedObject var store: SessionStore
    let onClose: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case day = "Day", range = "Range", all = "All"
        var id: Self { self }
    }

    @State private var mode: Mode = .day
    @State private var day = Date()
    @State private var from = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start
    @State private var to = Date()

    private let calendar = Calendar.current

    /// nil means every session.
    private var interval: DateInterval? {
        switch mode {
        case .all:
            return nil
        case .day:
            return calendar.dateInterval(of: .day, for: day)
        case .range:
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.dateInterval(of: .day, for: max(from, to))!.end
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
        let period = calendar.dateInterval(of: component, for: reference)!
        mode = .range
        from = period.start
        // The period's end is midnight of the next day; step back into the last day.
        to = min(period.end.addingTimeInterval(-1), Date())
    }

    private var fileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        switch mode {
        case .all: return "work-time-all.csv"
        case .day: return "work-time-\(f.string(from: day)).csv"
        case .range:
            let lo = f.string(from: min(from, to)), hi = f.string(from: max(from, to))
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

private struct SettingsTab: View {
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
