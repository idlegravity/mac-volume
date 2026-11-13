import AppKit

func speakerSymbolName(volume: Float, muted: Bool) -> String {
    if muted || volume <= 0 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

private final class LevelBar: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        track.fill()
        guard level > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * level)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Small on-screen volume indicator shown when the volume keys are pressed.
final class VolumeHUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 260, height: 52)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.frame = NSRect(x: 18, y: 14, width: 28, height: 24)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        background.addSubview(icon)

        bar.frame = NSRect(x: 56, y: 23, width: size.width - 56 - 22, height: 6)
        background.addSubview(bar)
    }

    func show(volume: Float, muted: Bool) {
        icon.image = NSImage(
            systemSymbolName: speakerSymbolName(volume: volume, muted: muted),
            accessibilityDescription: "Volume")
        bar.level = muted ? 0 : CGFloat(volume)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 90))
        }

        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
