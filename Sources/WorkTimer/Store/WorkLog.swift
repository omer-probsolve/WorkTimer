import Combine
import Foundation
import WorkTimerCore

/// Publishes `WorkMetrics` to the UI: changes whenever your sessions or the
/// agents' work change. All the calculations live in `WorkMetrics`.
final class WorkLog: ObservableObject {
    let store: SessionStore
    let agents: AgentMonitor
    let aiWorld: AIWorldMonitor
    let trackingStart: Date

    /// Every agent's segments, transcripts and AI World together, oldest first.
    private var segments: [AgentSegment] = []
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore, agents: AgentMonitor, aiWorld: AIWorldMonitor, trackingStart: Date) {
        self.store = store
        self.agents = agents
        self.aiWorld = aiWorld
        self.trackingStart = trackingStart
        agents.$segments.combineLatest(aiWorld.$segments)
            .sink { [weak self] transcripts, aiWorld in
                self?.segments = (transcripts + aiWorld).sorted { $0.span.start < $1.span.start }
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        Publishers.Merge(store.objectWillChange, agents.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// A snapshot of the current data to compute from.
    var metrics: WorkMetrics {
        WorkMetrics(log: store.log, segments: segments, trackingStart: trackingStart)
    }
}
