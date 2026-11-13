import AppKit

// `MacVolume --probe` sets up the audio path, prints what it found, and exits.
if CommandLine.arguments.contains("--probe") {
    let engine = AudioEngine()
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
