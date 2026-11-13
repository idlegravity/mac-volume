import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data(("[MacVolume] " + message + "\n").utf8))
}

// MARK: - Core Audio property helpers

enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        let value: Unmanaged<CFString>? = get(id, selector, initial: nil) ?? nil
        return value.map { $0.takeRetainedValue() as String }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = get(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// True if macOS can already adjust this device's output volume itself.
    static func hasVolumeControl(_ device: AudioObjectID) -> Bool {
        for element: AudioObjectPropertyElement in [0, 1, 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            if AudioObjectHasProperty(device, &addr) { return true }
        }
        return false
    }

    /// Number of buffers (streams) a device presents in the given scope.
    static func bufferCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    static func describeBuffers(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return "[]" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return "[]" }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return "[" + list.map { "\($0.mNumberChannels)ch" }.joined(separator: ", ") + "]"
    }

    static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: bytes, encoding: .ascii)! : "\(value)"
    }

    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard err == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}

// MARK: - Engine

/// Gives a volume-less output device a software volume.
///
/// Everything other apps play to the device is captured with a Core Audio process tap
/// (which also silences the original), scaled by our gain, and played to the device by us.
final class AudioEngine {
    private(set) var isActive = false
    private(set) var deviceName = "No output device"
    private(set) var lastError: String?
    var onStateChange: (() -> Void)?

    // Shared with the realtime IO thread; plain float reads/writes are fine here.
    private let targetGain: UnsafeMutablePointer<Float>
    private let currentGain: UnsafeMutablePointer<Float>

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var builtSampleRate: Float64 = 0
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var rebuildScheduled = false
    private let ioQueue = DispatchQueue(label: "MacVolume.io", qos: .userInteractive)

    init() {
        targetGain = .allocate(capacity: 1)
        currentGain = .allocate(capacity: 1)
        targetGain.initialize(to: 1)
        currentGain.initialize(to: 1)
    }

    func setGain(_ gain: Float) {
        targetGain.pointee = max(0, min(1, gain))
    }

    func start() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        rebuild()
    }

    func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    func rebuild() {
        teardown()
        lastError = nil
        defer { onStateChange?() }

        guard let dev = CA.defaultOutputDevice() else {
            deviceName = "No output device"
            return
        }
        deviceName = CA.string(dev, kAudioObjectPropertyName) ?? "Unknown device"

        if CA.hasVolumeControl(dev) {
            log("\(deviceName) has its own volume control; staying out of the way")
            return
        }
        do {
            try build(for: dev)
            isActive = true
            log("Software volume active for \(deviceName)")
        } catch {
            lastError = "\(error)"
            log("Failed to set up \(deviceName): \(error)")
            teardown()
        }
    }

    struct EngineError: Error, CustomStringConvertible {
        let description: String
        init(_ what: String, _ status: OSStatus = noErr) {
            description = status == noErr ? what : "\(what) (OSStatus \(status))"
        }
    }

    private func build(for dev: AudioObjectID) throws {
        guard let deviceUID = CA.string(dev, kAudioDevicePropertyDeviceUID) else {
            throw EngineError("Could not read device UID")
        }
        guard let ownProcess = CA.ownProcessObject() else {
            // Without this we would tap our own output and feed back.
            throw EngineError("Could not find our own audio process object")
        }

        // 1. Tap everything other processes send to the device's first output stream, muting the original.
        let tap = CATapDescription(excludingProcesses: [ownProcess], deviceUID: deviceUID, stream: 0)
        tap.uuid = UUID()
        tap.name = "MacVolume Tap"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tap, &newTap)
        guard err == noErr else { throw EngineError("Could not create process tap", err) }
        tapID = newTap

        // 2. Private aggregate device: the real device for output, the tap as an input.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacVolume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard err == noErr else { throw EngineError("Could not create aggregate device", err) }
        aggregateID = newAggregate

        // The aggregate's inputs are the device's own inputs (e.g. the Scarlett's mic/line ins)
        // followed by the tap. Skip the former so we never monitor live inputs.
        let deviceInputs = CA.bufferCount(dev, kAudioDevicePropertyScopeInput)
        let aggInputs = CA.bufferCount(newAggregate, kAudioDevicePropertyScopeInput)
        log("device in \(CA.describeBuffers(dev, kAudioDevicePropertyScopeInput)) out \(CA.describeBuffers(dev, kAudioDevicePropertyScopeOutput)); "
            + "aggregate in \(CA.describeBuffers(newAggregate, kAudioDevicePropertyScopeInput)) out \(CA.describeBuffers(newAggregate, kAudioDevicePropertyScopeOutput))")
        for stream in CA.streams(newAggregate, kAudioDevicePropertyScopeInput) {
            let name = CA.string(stream, kAudioObjectPropertyName) ?? "(tap)"
            let terminal = CA.get(stream, kAudioStreamPropertyTerminalType, initial: UInt32(0)) ?? 0
            log("  aggregate input stream: \(name) terminal=\(CA.fourCC(terminal))")
        }
        guard aggInputs > deviceInputs else {
            throw EngineError("Tap did not appear in the aggregate device (\(aggInputs) inputs)")
        }
        let tapOffset = deviceInputs

        // 3. IO: tap -> gain -> device.
        let target = targetGain
        let current = currentGain
        current.pointee = target.pointee
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, newAggregate, ioQueue) { _, inInput, _, outOutput, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let output = UnsafeMutableAudioBufferListPointer(outOutput)
            let from = current.pointee
            let to = target.pointee

            for index in 0..<output.count {
                guard let dst = output[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let outSamples = Int(output[index].mDataByteSize) / MemoryLayout<Float>.size
                var copied = 0
                let inIndex = tapOffset + index
                if inIndex < input.count, let src = input[inIndex].mData?.assumingMemoryBound(to: Float.self) {
                    copied = min(outSamples, Int(input[inIndex].mDataByteSize) / MemoryLayout<Float>.size)
                    if copied > 0 {
                        if from == to {
                            var gain = to
                            vDSP_vsmul(src, 1, &gain, dst, 1, vDSP_Length(copied))
                        } else {
                            // Ramp across the buffer so volume changes don't click.
                            var start = from
                            var step = (to - from) / Float(copied)
                            vDSP_vrampmul(src, 1, &start, &step, dst, 1, vDSP_Length(copied))
                        }
                    }
                }
                if copied < outSamples {
                    vDSP_vclr(dst + copied, 1, vDSP_Length(outSamples - copied))
                }
            }
            current.pointee = to
        }
        guard err == noErr, let proc else { throw EngineError("Could not create IO proc", err) }
        ioProcID = proc

        // Tell the HAL we don't read the device's own inputs, so it never opens the mic/line ins.
        if deviceInputs > 0 {
            let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (aggInputs - 1) * MemoryLayout<UInt32>.size
            let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
            usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
            usage.pointee.mNumberStreams = UInt32(aggInputs)
            let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
                .assumingMemoryBound(to: UInt32.self)
            for index in 0..<aggInputs { flags[index] = index >= deviceInputs ? 1 : 0 }
            var usageAddr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeInput)
            let usageErr = AudioObjectSetPropertyData(newAggregate, &usageAddr, 0, nil, UInt32(size), raw)
            if usageErr != noErr { log("Could not disable device input streams (OSStatus \(usageErr)); continuing") }
        }

        err = AudioDeviceStart(newAggregate, proc)
        guard err == noErr else { throw EngineError("Could not start audio", err) }

        // Rebuild if the device's sample rate changes underneath us.
        device = dev
        builtSampleRate = CA.get(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let rate = CA.get(self.device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
            if rate != self.builtSampleRate { self.scheduleRebuild() }
        }
        var rateAddr = CA.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(dev, &rateAddr, .main, listener)
        sampleRateListener = listener
    }

    func teardown() {
        isActive = false
        if let listener = sampleRateListener, device != kAudioObjectUnknown {
            var rateAddr = CA.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &rateAddr, .main, listener)
        }
        sampleRateListener = nil
        device = AudioObjectID(kAudioObjectUnknown)

        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
