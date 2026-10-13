import Combine
import Foundation
import WorkTimerCore

/// Publishes `WorkMetrics` to the UI: changes whenever your sessions or the
/// agents' work change. All the calculations live in `WorkMetrics`.
final class WorkLog: ObservableObject {
    let store: SessionStore
    let agents: AgentMonitor
    let trackingStart: Date

    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore, agents: AgentMonitor, trackingStart: Date) {
        self.store = store
        self.agents = agents
        self.trackingStart = trackingStart
        Publishers.Merge(store.objectWillChange, agents.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// A snapshot of the current data to compute from.
    var metrics: WorkMetrics {
        WorkMetrics(log: store.log, segments: agents.segments, trackingStart: trackingStart)
    }
}
