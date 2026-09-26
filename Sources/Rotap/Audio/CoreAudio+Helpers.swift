import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation)失败（OSStatus \(status)\(fourCC.map { " '\($0)'" } ?? "")）"
    }

    private var fourCC: String? {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result), "读取音频属性")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "读取音频属性")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func readObjectIDs(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "读取音频对象列表")
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids), "读取音频对象列表")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID.unknown
        try check(
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id),
            "查找进程音频对象"
        )
        return id
    }
}

/// Calls `onChange` on the main queue whenever a system-object property changes, until released.
final class AudioPropertyObserver {
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(_ selector: AudioObjectPropertySelector, onChange: @escaping @MainActor @Sendable () -> Void) {
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        block = { _, _ in MainActor.assumeIsolated { onChange() } }
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(.system, &address, .main, block)
    }
}
