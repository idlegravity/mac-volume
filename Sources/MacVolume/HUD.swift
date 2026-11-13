import AppKit

func speakerSymbolName(volume: Float, muted: Bool) -> String {
    if muted || volume <= 0 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

/// Thin level track with a row of step dots underneath, like the system volume overlay.
private final class LevelTrack: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }
    var steps = 16

    override func draw(_ dirtyRect: NSRect) {
        let trackHeight: CGFloat = 4
        let track = NSRect(x: 0, y: bounds.midY + 1, width: bounds.width, height: trackHeight)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        if level > 0 {
            var filled = track
            filled.size.width = max(trackHeight, track.width * min(1, level))
            NSColor.white.setFill()
            NSBezierPath(roundedRect: filled, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        }

        // One dot per step position, slightly inset from the ends of the track.
        let dot: CGFloat = 1.5
        let inset: CGFloat = 4
        let spacing = (track.width - inset * 2) / CGFloat(steps)
        NSColor.white.withAlphaComponent(0.4).setFill()
        for index in 0...steps {
            let x = inset + CGFloat(index) * spacing
            NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: track.minY - 5 - dot / 2, width: dot, height: dot)).fill()
        }
    }
}

/// Light tint and hairline rim drawn over the glass, so the pill reads clearly on any wallpaper.
private final class Backdrop: NSView {
    var cornerRadius: CGFloat = 24

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.withAlphaComponent(0.07).setFill()
        body.fill()

        // Rim highlight like the system glass: brightest at the top-left and bottom-right,
        // fading out toward the top-right and bottom-left corners.
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let rimRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rim = CGPath(
            roundedRect: rimRect, cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil)
        let stops: [(CGFloat, CGFloat)] = [(0, 0.75), (0.36, 0.5), (0.5, 0.05), (0.64, 0.5), (1, 0.75)]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { CGColor(red: 1, green: 1, blue: 1, alpha: $0.1) } as CFArray,
            locations: stops.map { $0.0 }) else { return }

        // Run the gradient perpendicular to the top-right/bottom-left diagonal, so those two corners
        // both land on its dim midpoint whatever the pill's proportions.
        let w = bounds.width, h = bounds.height
        let k = w * h / (w * w + h * h)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let start = CGPoint(x: center.x - k * h, y: center.y + k * w) // projects onto the top-left corner
        let end = CGPoint(x: center.x + k * h, y: center.y - k * w)   // and the bottom-right corner

        cg.saveGState()
        cg.addPath(rim.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 1))
        cg.clip()
        cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }
}

enum HUDPosition: String, CaseIterable {
    /// Top right under the menu bar, where macOS 26 shows its own.
    case native
    /// Bottom centre of the screen, where macOS showed it before.
    case classic

    var title: String {
        switch self {
        case .native: return "Native (Top Right)"
        case .classic: return "Classic (Bottom Center)"
        }
    }
}

/// On-screen volume indicator shown when the volume keys are pressed.
/// Modelled on the macOS 26 system overlay: a glass pill under the right end of the menu bar
/// with the device name, a level track, and speaker glyphs at either end.
final class VolumeHUD {
    private static let size = NSSize(width: 290, height: 62)
    /// Transparent space around the pill so its shadow has room to fall off.
    private static let margin: CGFloat = 44

    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let lowIcon = NSImageView()
    private let highIcon = NSImageView()
    private let track = LevelTrack()
    private var hideWork: DispatchWorkItem?
    private let content = NSView()
    var position: HUDPosition = .native

    init() {
        let size = Self.size
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width + Self.margin * 2, height: size.height + Self.margin * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // White content on dark glass regardless of the system appearance, like the system overlay.
        panel.appearance = NSAppearance(named: .darkAqua)

        content.frame = NSRect(origin: .zero, size: size)
        let backdrop = Backdrop(frame: content.bounds)
        content.addSubview(backdrop)

        title.frame = NSRect(x: 16, y: size.height - 12 - 16, width: size.width - 32, height: 16)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)

        let glyphs = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        lowIcon.frame = NSRect(x: 14, y: 13, width: 14, height: 16)
        lowIcon.symbolConfiguration = glyphs
        lowIcon.contentTintColor = .white
        lowIcon.imageAlignment = .alignLeft
        content.addSubview(lowIcon)

        highIcon.frame = NSRect(x: size.width - 16 - 20, y: 13, width: 20, height: 16)
        highIcon.symbolConfiguration = glyphs
        highIcon.contentTintColor = .white
        highIcon.imageAlignment = .alignLeft
        highIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        content.addSubview(highIcon)

        track.frame = NSRect(x: 34, y: 8, width: size.width - 34 - 42, height: 22)
        content.addSubview(track)

        let cornerRadius: CGFloat = 24
        let pillRect = NSRect(x: Self.margin, y: Self.margin, width: size.width, height: size.height)
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: size.width + Self.margin * 2, height: size.height + Self.margin * 2))
        container.wantsLayer = true
        panel.contentView = container

        // Soft drop shadow, like the system overlay. It is masked out of the pill's interior so it
        // only shows around the edge and doesn't darken the glass.
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let shadow = CALayer()
        shadow.frame = container.bounds
        shadow.shadowPath = pillPath
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.28
        shadow.shadowRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        let outside = CGMutablePath()
        outside.addRect(container.bounds)
        outside.addPath(pillPath)
        let mask = CAShapeLayer()
        mask.frame = container.bounds
        mask.path = outside
        mask.fillRule = .evenOdd
        shadow.mask = mask
        container.layer?.addSublayer(shadow)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: pillRect)
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            container.addSubview(glass)
        } else {
            let background = NSVisualEffectView(frame: pillRect)
            background.material = .hudWindow
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = cornerRadius
            background.layer?.masksToBounds = true
            background.addSubview(content)
            container.addSubview(background)
        }
    }

    /// Renders the overlay's contents (without the glass) on a dark backdrop, for checking layout.
    func snapshot() -> Data? {
        let view = content
        let scale = 4
        let size = Self.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 24, yRadius: 24).fill()
        view.displayIgnoringOpacity(view.bounds, in: context)
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    func show(volume: Float, muted: Bool, deviceName: String) {
        title.stringValue = deviceName
        let silent = muted || volume <= 0
        lowIcon.image = NSImage(
            systemSymbolName: silent ? "speaker.slash.fill" : "speaker.fill",
            accessibilityDescription: silent ? "Muted" : "Volume")
        track.level = muted ? 0 : CGFloat(volume)

        // On the screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            switch position {
            case .native:
                panel.setFrameOrigin(NSPoint(
                    x: screen.frame.maxX - Self.size.width - 22 - Self.margin,
                    y: screen.visibleFrame.maxY - 8 - Self.size.height - Self.margin))
            case .classic:
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - Self.size.width / 2 - Self.margin,
                    y: screen.visibleFrame.minY + 90 - Self.margin))
            }
        }

        hideWork?.cancel()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
