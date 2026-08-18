#ifndef AudioOrbit_AudioBridge_h
#define AudioOrbit_AudioBridge_h

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct AOAudioBridge AOAudioBridge;

typedef struct AOAudioBridgeSnapshot {
    uint64_t captureCallbackCount;
    uint64_t renderCallbackCount;
    uint64_t captureRequestedFrameCount;
    uint64_t renderRequestedFrameCount;
    uint64_t capturedFrameCount;
    uint64_t renderedFrameCount;
    uint64_t nonSilentFrameCount;
    uint64_t consumedSourceFrameCount;
    uint64_t queuedFrameCount;
    uint64_t maximumQueuedFrameCount;
    uint64_t underflowCount;
    uint64_t underflowFrameCount;
    uint64_t overflowCount;
    uint64_t overflowFrameCount;
    uint32_t capacityFrameCount;
    uint32_t targetQueuedFrameCount;
    uint32_t isPrimed;
    uint32_t gainRampRemainingFrameCount;
    double sourceSampleRate;
    double outputSampleRate;
    float rateCorrectionPPM;
    float currentGain;
} AOAudioBridgeSnapshot;

AOAudioBridge * _Nullable AOAudioBridgeCreate(
    AudioStreamBasicDescription format,
    double outputSampleRate,
    uint32_t capacityFrames,
    uint32_t gainRampFrames
);

void AOAudioBridgeDestroy(AOAudioBridge * _Nullable bridge);
void AOAudioBridgeReset(AOAudioBridge * _Nullable bridge);
void AOAudioBridgeResetQueueWatermark(AOAudioBridge * _Nullable bridge);
// Call with the output consumer stopped immediately before starting it. Frames
// already queued and frames accumulated through its first callback are dropped.
void AOAudioBridgePrepareForOutputStart(AOAudioBridge * _Nonnull bridge);
// Reconfigures a stopped output consumer, discards frames captured for the old
// destination, and returns the bridge to its unprimed state.
bool AOAudioBridgeConfigureOutputSampleRate(
    AOAudioBridge * _Nonnull bridge,
    double outputSampleRate
);

// Control-plane request consumed by the output callback without locking.
void AOAudioBridgeBeginGainRamp(
    AOAudioBridge * _Nonnull bridge,
    float targetGain,
    uint32_t durationFrames
);

// Real-time producer entry point. Copies at most one bounded input period.
void AOAudioBridgeWrite(
    AOAudioBridge * _Nonnull bridge,
    const AudioBufferList * _Nullable inputData
);

// Real-time producer callback registered directly with the tap aggregate device.
OSStatus AOAudioBridgeCaptureIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

// Real-time consumer entry point registered directly with the AUHAL renderer.
OSStatus AOAudioBridgeRender(
    void * _Nonnull inRefCon,
    AudioUnitRenderActionFlags * _Nonnull ioActionFlags,
    const AudioTimeStamp * _Nonnull inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList * _Nullable ioData
);

AOAudioBridgeSnapshot AOAudioBridgeRead(const AOAudioBridge * _Nonnull bridge);

#endif
