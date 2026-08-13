import CoreAudio
import Foundation

enum CoreAudioProperty {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func value<T>(
        _ type: T.Type = T.self,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        defer { storage.deallocate() }
        try requireNoErr(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
            operation: "Read Core Audio property \(selector.fourCC)"
        )
        return storage.load(as: T.self)
    }

    static func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectHasProperty(objectID, &address)
    }

    static func isSettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    static func setFloat32(
        _ value: Float32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var mutableValue = value
        try requireNoErr(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutableValue
            ),
            operation: "Set Core Audio property \(selector.fourCC)"
        )
    }

    static func array<T>(
        _ type: T.Type = T.self,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size: UInt32 = 0
        try requireNoErr(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            operation: "Size Core Audio property \(selector.fourCC)"
        )
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<T>.stride
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }

        var mutableSize = size
        try requireNoErr(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &mutableSize, storage),
            operation: "Read Core Audio property \(selector.fourCC)"
        )
        let values = storage.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }

    static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try requireNoErr(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &result),
            operation: "Read Core Audio string property \(selector.fourCC)"
        )
        guard let result else {
            throw CoreAudioError(operation: "Read Core Audio string property \(selector.fourCC)", status: kAudioHardwareUnspecifiedError)
        }
        return result.takeRetainedValue() as String
    }

    static func channelCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try requireNoErr(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            operation: "Size audio stream configuration"
        )
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try requireNoErr(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
            operation: "Read audio stream configuration"
        )

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + $1.mNumberChannels
        }
    }
}

extension FourCharCode {
    var fourCC: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(self)
    }
}
