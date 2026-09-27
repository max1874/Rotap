import CoreAudio
import Foundation

/// What a recording captures.
enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case system, microphone, both

    var id: String { rawValue }
    var includesSystem: Bool { self != .microphone }
    var includesMicrophone: Bool { self != .system }

    var title: LocalizedStringResource {
        switch self {
        case .system: "System Audio Only"
        case .microphone: "Microphone Only"
        case .both: "System Audio + Microphone"
        }
    }
}

/// A Core Audio device with input channels.
struct InputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }

    static func all() -> [InputDevice] {
        let devices = (try? AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices)) ?? []
        return devices.compactMap { device in
            let inputStreams = (try? device.readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
            guard !inputStreams.isEmpty,
                  let uid = try? device.readString(kAudioDevicePropertyDeviceUID),
                  let name = try? device.readString(kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    static func defaultDevice() -> InputDevice? {
        guard let device = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID.unknown),
              device != .unknown,
              let uid = try? device.readString(kAudioDevicePropertyDeviceUID),
              let name = try? device.readString(kAudioObjectPropertyName)
        else { return nil }
        return InputDevice(uid: uid, name: name)
    }

    /// Calls `onChange` on the main queue when devices are added/removed or the default input changes.
    static func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> [AnyObject] {
        [
            AudioPropertyObserver(kAudioHardwarePropertyDevices, onChange: onChange),
            AudioPropertyObserver(kAudioHardwarePropertyDefaultInputDevice, onChange: onChange),
        ]
    }
}
