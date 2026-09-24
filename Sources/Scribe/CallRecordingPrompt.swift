import AppKit
import SwiftUI

@MainActor
final class CallRecordingPrompt {
    private let panel: NSPanel
    private var currentCall: DetectedCall?
    private var currentError: String?

    init() {
        panel = CallPromptPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above other apps' floating call windows and full-screen meetings.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Call detected")
    }

    func show(call: DetectedCall, error: String?, record: @escaping (Bool) -> Void, dismiss: @escaping () -> Void) {
        guard !panel.isVisible || currentCall != call || currentError != error else { return }
        currentCall = call
        currentError = error
        let view = NSHostingView(rootView: CallPromptView(call: call, error: error, record: record, dismiss: dismiss))
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        panel.contentView = view
        panel.setFrame(NSRect(x: frame.minX + 20, y: frame.minY + 20,
                             width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private final class CallPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CallPromptView: View {
    let call: DetectedCall
    let error: String?
    let record: (Bool) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .padding(9)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(call.name) detected").font(.headline)
                    Text("Record this call with Kleio?")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.plain)
                    .help("Dismiss for this call")
                    .accessibilityLabel("Dismiss for this call")
            }
            Text("Your microphone and \(call.application.name) audio. Screen recording lets you choose a display.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if MeetingMuteParser.Provider.native(bundleID: call.application.bundleID) == nil,
               call.application.bundleID != "com.apple.FaceTime" {
                Text("Browser audio includes all audible tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { record(false) } label: {
                    Label("Audio", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { record(true) } label: {
                    Label("Audio + screen", systemImage: "rectangle.inset.filled.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
    }
}
