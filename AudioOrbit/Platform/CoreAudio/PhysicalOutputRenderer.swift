import AudioToolbox
import CoreAudio
import Foundation

final class PhysicalOutputRenderer {
    private var audioUnit: AudioUnit?
    private(set) var isStarted = false

    func prepare(
        deviceID: AudioObjectID,
        clientFormat: AudioStreamBasicDescription,
        bridge: OpaquePointer
    ) throws {
        guard audioUnit == nil else { return }

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw CoreAudioError(
                operation: "Find the HAL output audio unit",
                status: kAudioHardwareUnspecifiedError
            )
        }

        var createdUnit: AudioUnit?
        try requireNoErr(
            AudioComponentInstanceNew(component, &createdUnit),
            operation: "Create the HAL output audio unit"
        )
        guard let createdUnit else {
            throw CoreAudioError(
                operation: "Create the HAL output audio unit",
                status: kAudioHardwareUnspecifiedError
            )
        }
        audioUnit = createdUnit

        do {
            var outputEnabled: UInt32 = 1
            try requireNoErr(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &outputEnabled,
                    UInt32(MemoryLayout.size(ofValue: outputEnabled))
                ),
                operation: "Enable HAL output"
            )

            var mutableDeviceID = deviceID
            try requireNoErr(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &mutableDeviceID,
                    UInt32(MemoryLayout.size(ofValue: mutableDeviceID))
                ),
                operation: "Bind the HAL output to the selected device"
            )

            var mutableFormat = clientFormat
            try requireNoErr(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &mutableFormat,
                    UInt32(MemoryLayout.size(ofValue: mutableFormat))
                ),
                operation: "Set the HAL output client format"
            )

            var callback = AURenderCallbackStruct(
                inputProc: AOAudioBridgeRender,
                inputProcRefCon: UnsafeMutableRawPointer(bridge)
            )
            try requireNoErr(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout.size(ofValue: callback))
                ),
                operation: "Install the HAL output render callback"
            )

            try requireNoErr(
                AudioUnitInitialize(createdUnit),
                operation: "Initialize the HAL output"
            )
        } catch {
            tearDownIgnoringErrors()
            throw error
        }
    }

    func start() throws {
        guard let audioUnit, !isStarted else { return }
        try requireNoErr(
            AudioOutputUnitStart(audioUnit),
            operation: "Start the selected-device renderer"
        )
        isStarted = true
    }

    func stop() throws {
        var firstError: Error?
        if let audioUnit, isStarted {
            let status = AudioOutputUnitStop(audioUnit)
            if status != noErr {
                firstError = CoreAudioError(
                    operation: "Stop the selected-device renderer",
                    status: status
                )
            }
            isStarted = false
        }

        if let audioUnit {
            let uninitializeStatus = AudioUnitUninitialize(audioUnit)
            if uninitializeStatus != noErr, firstError == nil {
                firstError = CoreAudioError(
                    operation: "Uninitialize the selected-device renderer",
                    status: uninitializeStatus
                )
            }
            let disposeStatus = AudioComponentInstanceDispose(audioUnit)
            if disposeStatus != noErr, firstError == nil {
                firstError = CoreAudioError(
                    operation: "Dispose the selected-device renderer",
                    status: disposeStatus
                )
            }
            self.audioUnit = nil
        }

        if let firstError { throw firstError }
    }

    private func tearDownIgnoringErrors() {
        if let audioUnit {
            if isStarted {
                AudioOutputUnitStop(audioUnit)
            }
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            isStarted = false
        }
    }

    deinit {
        tearDownIgnoringErrors()
    }
}
