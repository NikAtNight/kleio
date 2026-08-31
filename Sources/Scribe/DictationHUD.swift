import AppKit

/// A compact, non-activating indication that system-wide dictation is active.
@MainActor
final class DictationHUD {
    enum Phase {
        case preparing
        case recording
        case transcribing
    }

    private static let size = NSSize(width: 280, height: 64)
    private static let originKey = "dictationHUDOrigin"

    private let panel: HUDPanel
    private let visualizer: DictationHUDView
    private var programmaticMove = false
    private var moveObserver: NSObjectProtocol?

    init?() {
        guard NSApp != nil else { return nil }

        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        visualizer = DictationHUDView(frame: NSRect(origin: .zero, size: Self.size))
        let background = NSVisualEffectView(frame: visualizer.bounds)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        visualizer.autoresizingMask = [.width, .height]
        background.addSubview(visualizer)
        panel.contentView = background

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.programmaticMove, self.panel.isVisible else { return }
                UserDefaults.standard.set(
                    NSStringFromPoint(self.panel.frame.origin),
                    forKey: Self.originKey
                )
            }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func show(_ phase: Phase) {
        placePanel()
        visualizer.setPhase(phase)
        visualizer.startAnimating()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func setPhase(_ phase: Phase) {
        guard panel.isVisible else {
            show(phase)
            return
        }
        visualizer.setPhase(phase)
    }

    func update(level: Float) {
        visualizer.ingest(level: level)
    }

    func hide() {
        visualizer.stopAnimating()
        panel.orderOut(nil)
    }

    private func placePanel() {
        let origin = Self.savedOrigin.flatMap { origin in
            Self.isVisible(origin: origin, size: Self.size) ? origin : nil
        } ?? Self.defaultOrigin()
        programmaticMove = true
        panel.setFrameOrigin(origin)
        programmaticMove = false
    }

    private static var savedOrigin: NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: originKey) else { return nil }
        return NSPointFromString(string)
    }

    private static func defaultOrigin() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return .zero }
        return NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 64
        )
    }

    private static func isVisible(origin: NSPoint, size: NSSize) -> Bool {
        let frame = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DictationHUDView: NSView {
    override var isFlipped: Bool { true }

    private enum Phase { case preparing, recording, transcribing }

    private var phase: Phase = .preparing
    private var phaseStart: CGFloat = 0
    private var time: CGFloat = 0
    private var level: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var agcReference: CGFloat = 0.35
    private var timer: Timer?
    private var features = VoiceFeatures()

    func setPhase(_ newPhase: DictationHUD.Phase) {
        phase = switch newPhase {
        case .preparing: .preparing
        case .recording: .recording
        case .transcribing: .transcribing
        }
        phaseStart = time
        needsDisplay = true
    }

    func ingest(level: Float) {
        let input = max(0, CGFloat(level))
        agcReference = max(agcReference * 0.995, input, 0.08)
        self.level = max(self.level, min(1, input / agcReference * 0.9))
    }

    func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        time = 0
        level = 0
        displayedLevel = 0
        agcReference = 0.35
        features.reset()
    }

    private func tick() {
        let target = level
        level = 0
        displayedLevel = target > displayedLevel
            ? displayedLevel + (target - displayedLevel) * 0.62
            : displayedLevel * 0.80
        time += 1.0 / 30.0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch phase {
        case .preparing:
            drawDots(in: context, chasing: false)
        case .recording:
            drawWave(in: context)
        case .transcribing:
            drawDots(in: context, chasing: true)
        }
    }

    private func drawDots(in context: CGContext, chasing: Bool) {
        let pulse = 0.55 + 0.45 * sin(time * (chasing ? 5 : 3))
        context.saveGState()
        context.setShadow(offset: .zero, blur: 7, color: NSColor.systemTeal.withAlphaComponent(0.4).cgColor)
        for index in 0..<3 {
            let offset = CGFloat(index - 1) * 18
            let alpha: CGFloat
            if chasing {
                alpha = 0.32 + 0.68 * max(0, sin(time * 5 - CGFloat(index) * 1.1))
            } else {
                alpha = 0.35 + 0.55 * pulse
            }
            context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: bounds.midX + offset - 4, y: bounds.midY - 4, width: 8, height: 8))
        }
        context.restoreGState()
    }

    private func drawWave(in context: CGContext) {
        let spectrum = SyntheticSpeech.spectrum(at: Double(time), level: Float(displayedLevel)).map(CGFloat.init)
        features.update(time: time, deltaTime: 1.0 / 30.0, level: displayedLevel, spectrum: spectrum)
        let barCount = 25
        let spacing: CGFloat = 4
        let width = (bounds.width - 52 - CGFloat(barCount - 1) * spacing) / CGFloat(barCount)
        let maximumHeight = bounds.height - 20
        let ramp = HudRamp([(0, "#58D6C9"), (0.55, "#86E8B9"), (1, "#9AA9FA")])

        context.saveGState()
        context.setShadow(offset: .zero, blur: 8, color: NSColor.systemTeal.withAlphaComponent(0.28).cgColor)
        for index in 0..<barCount {
            let position = CGFloat(index) / CGFloat(barCount - 1)
            let band = spectrum[index * spectrum.count / barCount]
            let envelope = pow(sin(.pi * position), 0.65)
            let shimmer = 0.72 + 0.28 * sin(time * 4 + CGFloat(index) * 0.74)
            let pitch = 0.82 + features.centroid * 0.18
            let onsetGlow = features.onset ? features.onsetStrength * 0.16 : 0
            let energy = max(0.08, (band * 0.82 + displayedLevel * 0.5 + onsetGlow) * shimmer * pitch)
            let height = min(maximumHeight, 5 + energy * maximumHeight * envelope)
            let rect = CGRect(x: 26 + CGFloat(index) * (width + spacing), y: bounds.midY - height / 2, width: width, height: height)
            let color = ramp.color(at: position).cgColor(opacity: 0.72 + 0.28 * energy)
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }
}
