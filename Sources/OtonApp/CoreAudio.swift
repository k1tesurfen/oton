import OtonCore
import CoreAudio
import Foundation

enum CA {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var addr = address(sel, scope)
        var v = def
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
        return err == noErr ? v : def
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)
}

struct InputDevice: Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: UInt32
    var channels: Int

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isUSB: Bool { transport == kAudioDeviceTransportTypeUSB }

    var kind: MicKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return .continuity
        default: return .other
        }
    }

    var mic: Mic { Mic(name: name, uid: uid, kind: kind) }
}

enum Devices {
    /// Every device with input channels.
    static func inputs() -> [InputDevice] {
        CA.ids(CA.system, kAudioHardwarePropertyDevices).compactMap { id in
            let channels = inputChannels(id)
            guard channels > 0 else { return nil }
            return InputDevice(id: id, uid: CA.string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: CA.string(id, kAudioObjectPropertyName) ?? "Unknown",
                               transport: CA.get(id, kAudioDevicePropertyTransportType, UInt32(0)), channels: channels)
        }
    }

    /// The device to record: see `pickMic`.
    static func pick(preferred: [String], lidClosed: Bool) -> InputDevice? {
        let all = inputs()
        guard let m = pickMic(all.map(\.mic), preferred: preferred, lidClosed: lidClosed) else { return nil }
        return all.first { $0.uid == m.uid }
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Calls `onChange` on the main queue whenever a device is plugged in or removed.
    static func watch(_ onChange: @escaping () -> Void) {
        var addr = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { _, _ in onChange() }
    }
}
