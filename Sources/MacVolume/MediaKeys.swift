import AppKit
import CoreGraphics

enum MediaKey {
    case volumeUp, volumeDown, mute
}

/// Intercepts the keyboard's volume keys before macOS handles them.
/// Needs Accessibility permission (an event tap that can swallow events).
final class MediaKeyTap {
    /// Called on key down (and repeats). Return true to swallow the key, false to let macOS handle it.
    var handler: ((MediaKey, _ fine: Bool, _ isDown: Bool) -> Bool)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let systemDefined = CGEventMask(1) << 14 // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

private func mediaKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return pass
    }
    guard type.rawValue == 14,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 // media / aux control keys
    else { return pass }

    let data = nsEvent.data1
    let keyCode = (data & 0xFFFF_0000) >> 16
    let isDown = ((data & 0xFF00) >> 8) == 0xA

    let key: MediaKey
    switch keyCode {
    case 0: key = .volumeUp     // NX_KEYTYPE_SOUND_UP
    case 1: key = .volumeDown   // NX_KEYTYPE_SOUND_DOWN
    case 7: key = .mute         // NX_KEYTYPE_MUTE
    default: return pass
    }

    let flags = event.flags
    let fine = flags.contains(.maskShift) && flags.contains(.maskAlternate)
    let swallow = tap.handler?(key, fine, isDown) ?? false
    return swallow ? nil : pass
}
