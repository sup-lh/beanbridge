import CoreAudio
import Foundation

enum SystemInputError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case unavailable
    case selectionDidNotStick

    var description: String {
        switch self {
        case let .status(operation, status): return "\(operation)失败（\(status)）"
        case .unavailable: return "找不到 BlackHole 2ch 输入设备"
        case .selectionDidNotStick: return "无法将系统输入切换到 BlackHole 2ch"
        }
    }
}

final class SystemInputSwitch {
    private let previous: AudioObjectID
    private let target: AudioObjectID
    private var changed = false

    init(targetUID: String = "BlackHole2ch_UID") throws {
        previous = try Self.current()
        var uid = targetUID as CFString
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &object
            )
        }
        guard status == noErr else { throw SystemInputError.status("查找虚拟麦克风", status) }
        guard object != kAudioObjectUnknown else { throw SystemInputError.unavailable }
        target = object
    }

    static func current() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard status == noErr else { throw SystemInputError.status("读取系统输入", status) }
        return value
    }

    private static func select(_ value: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutable = value
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &mutable
        )
        guard status == noErr else { throw SystemInputError.status("切换系统输入", status) }
    }

    func activate() throws {
        guard previous != target else { return }
        try Self.select(target)
        changed = true
        guard try Self.current() == target else { throw SystemInputError.selectionDidNotStick }
    }

    func restoreIfUnchanged() {
        guard changed else { return }
        do {
            guard try Self.current() == target else { return }
            try Self.select(previous)
            log("已恢复此前的系统麦克风。")
        } catch {
            log("未能自动恢复系统麦克风：\(error)。请在系统设置 → 声音中手动选择。")
        }
    }
}
