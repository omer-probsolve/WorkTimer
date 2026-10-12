import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { recording ? stopRecording() : startRecording() }) {
                Text(recording ? "Type shortcut…" : (combo?.displayString ?? "None"))
                    .monospacedDigit()
                    .frame(minWidth: 96)
            }
            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
            } else if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
