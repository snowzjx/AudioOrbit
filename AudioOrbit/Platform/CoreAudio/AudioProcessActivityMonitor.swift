import CoreAudio
import Foundation

/// Observes the audio process table so playback starts, playback stops, and
/// process churn (for example a WebKit media helper relaunching) surface as
/// events instead of waiting for the next poll.
///
/// kAudioHardwarePropertyProcessObjectList is a notifying property: the
/// system fires it whenever a process establishes or tears down its audio
/// connection, which is exactly when playback starts or stops. The per-
/// process kAudioProcessPropertyIsRunningOutput property is NOT notifying
/// (verified empirically), so the model re-reads the full snapshot when this
/// event arrives instead of watching each process.
final class AudioProcessActivityMonitor {
    var onActivityChange: (() -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.audioorbit.process-monitor")
    private var isStarted = false

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onActivityChange?()
        }
    }

    func start() throws {
        guard !isStarted else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
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
            operation: "Observe the audio-process list"
        )
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
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

    deinit {
        stop()
    }
}
