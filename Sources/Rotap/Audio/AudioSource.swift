import AppKit
import CoreAudio

/// Something Rotap can record: either everything the Mac plays, or one app (all of its audio processes).
struct AudioSource: Identifiable, Hashable, Sendable {
    static let systemID = "system"
    static let system = AudioSource(id: systemID, name: "全部系统声音", appPath: nil, processObjectIDs: [], isPlaying: false)

    let id: String
    let name: String
    /// Bundle path of the owning app, for its icon.
    let appPath: String?
    let processObjectIDs: [AudioObjectID]
    let isPlaying: Bool

    var isSystem: Bool { id == Self.systemID }
    /// Short label used for file names and recording titles.
    var label: String { isSystem ? "系统声音" : name }

    /// Groups Core Audio process objects by owning app, so e.g. Chrome's helper processes count as Chrome.
    @MainActor
    static func available() -> [AudioSource] {
        let objectIDs = (try? AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList)) ?? []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        struct Group { var name: String; var app: NSRunningApplication?; var ids: [AudioObjectID]; var playing: Bool }
        var groups: [String: Group] = [:]

        for objectID in objectIDs {
            guard let pid = try? objectID.read(kAudioProcessPropertyPID, default: pid_t(0)), pid != ownPID else { continue }
            let bundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
            let playing = ((try? objectID.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0

            let owner = apps.first { app in
                guard let appID = app.bundleIdentifier, !bundleID.isEmpty else { return app.processIdentifier == pid }
                return bundleID == appID || bundleID.hasPrefix(appID + ".") || app.processIdentifier == pid
            }
            guard let key = owner?.bundleIdentifier ?? (bundleID.isEmpty ? nil : bundleID) else { continue }
            let name = (owner ?? NSRunningApplication(processIdentifier: pid))?.localizedName ?? bundleID

            var group = groups[key] ?? Group(name: name, app: owner, ids: [], playing: false)
            group.ids.append(objectID)
            group.playing = group.playing || playing
            groups[key] = group
        }

        return groups
            .filter { $0.value.app != nil || $0.value.playing }
            .map { key, group in
                AudioSource(id: key, name: group.name, appPath: group.app?.bundleURL?.path,
                            processObjectIDs: group.ids, isPlaying: group.playing)
            }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
    }

    /// Calls `onChange` on the main queue whenever the set of audio clients changes, until the token is released.
    static func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyObject {
        AudioPropertyObserver(kAudioHardwarePropertyProcessObjectList, onChange: onChange)
    }
}
