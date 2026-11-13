import AppKit

// `MacVolume --probe [--buffer N]` sets up the audio path, prints what it found, and exits.
if CommandLine.arguments.contains("--probe") {
    let engine = AudioEngine()
    if let flag = CommandLine.arguments.firstIndex(of: "--buffer"), flag + 1 < CommandLine.arguments.count {
        engine.requestedBufferFrames = UInt32(CommandLine.arguments[flag + 1]) ?? 0
    }
    engine.rebuild()
    log("active=\(engine.isActive) device=\(engine.deviceName) error=\(engine.lastError ?? "none")")
    engine.teardown()
    exit(engine.lastError == nil ? 0 : 1)
}

// `MacVolume --hud-demo [--classic]` shows the volume overlay for a few seconds without touching audio.
if CommandLine.arguments.contains("--hud-demo") {
    let demo = NSApplication.shared
    demo.setActivationPolicy(.accessory)
    let hud = VolumeHUD()
    if CommandLine.arguments.contains("--classic") { hud.position = .classic }
    var level: Float = 0.25
    hud.show(volume: level, muted: false, deviceName: "Scarlett Solo USB")
    // `--hud-demo <file.png>` also saves a layout snapshot and exits.
    if let flag = CommandLine.arguments.firstIndex(of: "--hud-demo"), flag + 1 < CommandLine.arguments.count,
       CommandLine.arguments[flag + 1].hasSuffix(".png") {
        hud.show(volume: 0.6875, muted: false, deviceName: "Scarlett Solo USB")
        try? hud.snapshot()?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        exit(0)
    }
    Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
        level = min(1, level + 0.125)
        hud.show(volume: level, muted: false, deviceName: "Scarlett Solo USB")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    demo.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
