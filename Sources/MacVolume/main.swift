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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
