import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let steps: Float = 16

    private let engine = AudioEngine()
    private let keys = MediaKeyTap()
    private let hud = VolumeHUD()
    private let defaults = UserDefaults.standard

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(
        title: "Grant Accessibility Access for Volume Keys…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var accessibilityTimer: Timer?
    private let bufferItem = NSMenuItem(title: "Buffer Size", action: nil, keyEquivalent: "")
    /// 0 means "leave the system default".
    private static let bufferChoices: [Int] = [0, 64, 128, 256, 512, 1024]

    private var volume: Float = 1
    private var muted = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["volume": 1.0, "muted": false, "bufferFrames": 0])
        volume = max(0, min(1, defaults.float(forKey: "volume")))
        muted = defaults.bool(forKey: "muted")
        engine.requestedBufferFrames = UInt32(max(0, defaults.integer(forKey: "bufferFrames")))

        buildMenu()
        applyVolume(showHUD: false)

        engine.onStateChange = { [weak self] in self?.refreshUI() }
        engine.start()

        keys.handler = { [weak self] key, fine, isDown in
            guard let self, self.engine.isActive else { return false }
            if isDown { self.handle(key, fine: fine) }
            return true
        }
        startKeyTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engine.scheduleRebuild() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.teardown()
    }

    // MARK: Volume

    private func handle(_ key: MediaKey, fine: Bool) {
        let step = (fine ? 0.25 : 1) / Self.steps
        switch key {
        case .volumeUp:
            volume = min(1, volume + step)
            muted = false
        case .volumeDown:
            volume = max(0, volume - step)
            if volume > 0 { muted = false }
        case .mute:
            muted.toggle()
        }
        applyVolume(showHUD: true)
    }

    private func applyVolume(showHUD: Bool) {
        // Squared taper: steps feel roughly even to the ear.
        engine.setGain(muted ? 0 : volume * volume)
        defaults.set(volume, forKey: "volume")
        defaults.set(muted, forKey: "muted")
        refreshUI()
        if showHUD { hud.show(volume: volume, muted: muted) }
    }

    @objc private func sliderChanged() {
        volume = slider.floatValue
        muted = false
        applyVolume(showHUD: false)
    }

    @objc private func toggleMute() {
        muted.toggle()
        applyVolume(showHUD: false)
    }

    // MARK: Volume keys / Accessibility

    private func startKeyTap() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt), keys.start() {
            refreshUI()
            return
        }
        // Not trusted yet: keep checking until the user grants access.
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.keys.start() else { return }
            timer.invalidate()
            self.accessibilityTimer = nil
            self.refreshUI()
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let sliderItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        slider.frame = NSRect(x: 16, y: 4, width: 208, height: 22)
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        container.addSubview(slider)
        sliderItem.view = container
        menu.addItem(sliderItem)

        muteItem.target = self
        menu.addItem(muteItem)
        menu.addItem(.separator())

        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let bufferMenu = NSMenu()
        bufferMenu.autoenablesItems = false
        for frames in Self.bufferChoices {
            let item = NSMenuItem(title: "", action: #selector(selectBufferSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = frames
            bufferMenu.addItem(item)
        }
        bufferItem.submenu = bufferMenu
        menu.addItem(bufferItem)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacVolume", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    private func refreshUI() {
        guard statusItem != nil else { return }
        let active = engine.isActive

        let symbol = active ? speakerSymbolName(volume: volume, muted: muted) : "speaker.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacVolume")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !active

        if let error = engine.lastError {
            statusLine.title = "Error: \(error)"
        } else if active {
            statusLine.title = "\(engine.deviceName) — \(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")"
        } else {
            statusLine.title = "\(engine.deviceName) — using system volume"
        }

        slider.floatValue = volume
        slider.isEnabled = active
        muteItem.state = muted ? .on : .off
        muteItem.isEnabled = active
        accessibilityItem.isHidden = keys.isRunning

        let selected = Int(engine.requestedBufferFrames)
        let rate = engine.sampleRate
        func milliseconds(_ frames: Int) -> String {
            rate > 0 ? String(format: "%.1f ms", Double(frames) / rate * 1000) : ""
        }
        for item in bufferItem.submenu?.items ?? [] {
            if item.tag == 0 {
                // Only when the default is selected do we know what the default actually is.
                let actual = Int(engine.bufferFrames)
                item.title = selected == 0 && actual > 0
                    ? "System Default (\(actual) frames, \(milliseconds(actual)))"
                    : "System Default"
            } else {
                item.title = rate > 0 ? "\(item.tag) frames (\(milliseconds(item.tag)))" : "\(item.tag) frames"
            }
            item.state = item.tag == selected ? .on : .off
        }
        let inUse = Int(engine.bufferFrames)
        bufferItem.title = active && inUse > 0 ? "Buffer Size: \(inUse) frames (\(milliseconds(inUse)))" : "Buffer Size"

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func selectBufferSize(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "bufferFrames")
        engine.requestedBufferFrames = UInt32(sender.tag)
        engine.rebuild() // brief dropout while the audio path restarts
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("Launch at login change failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refreshUI()
    }
}
