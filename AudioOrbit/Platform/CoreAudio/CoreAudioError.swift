import CoreAudio
import Foundation

struct CoreAudioError: Error, Equatable, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var fourCharacterCode: String? {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    var description: String {
        if let fourCharacterCode {
            return "\(operation) failed (\(fourCharacterCode), \(status))."
        }
        return "\(operation) failed (OSStatus \(status))."
    }
}

@inline(__always)
func requireNoErr(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError(operation: operation, status: status)
    }
}
