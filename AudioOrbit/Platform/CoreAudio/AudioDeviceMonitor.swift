import CoreAudio
import Foundation

final class AudioDeviceMonitor {
    var onChange: (() -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.audioorbit.device-monitor")
    private var isStarted = false
    private var watchedDeviceIDs: Set<AudioObjectID> = []

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    func start() throws {
        guard !isStarted else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try requireNoErr(
            AudioObjectAddPropertyListenerBlock(
                CoreAudioProperty.systemObject,
                &address,
                listenerQueue,
                listenerBlock
            ),
            operation: "Observe the audio-device list"
        )
        isStarted = true
    }

    func watchAliveStates(of deviceIDs: Set<AudioObjectID>) throws {
        for deviceID in watchedDeviceIDs.subtracting(deviceIDs) {
            removeAliveListener(from: deviceID)
            watchedDeviceIDs.remove(deviceID)
        }

        for deviceID in deviceIDs.subtracting(watchedDeviceIDs) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try requireNoErr(
                AudioObjectAddPropertyListenerBlock(
                    deviceID,
                    &address,
                    listenerQueue,
                    listenerBlock
                ),
                operation: "Observe a routed output's availability"
            )
            watchedDeviceIDs.insert(deviceID)
        }
    }

    func stop() {
        for deviceID in watchedDeviceIDs {
            removeAliveListener(from: deviceID)
        }
        watchedDeviceIDs.removeAll()

        guard isStarted else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            CoreAudioProperty.systemObject,
            &address,
            listenerQueue,
            listenerBlock
        )
        isStarted = false
    }

    private func removeAliveListener(from deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            listenerBlock
        )
    }

    deinit {
        stop()
    }
}
