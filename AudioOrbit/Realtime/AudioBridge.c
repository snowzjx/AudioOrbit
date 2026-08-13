#include "AudioBridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define AO_GAIN_UNITY_Q31 INT32_MAX
#define AO_QUEUE_CORRECTION_PPM_PER_FRAME 2.0
#define AO_QUEUE_ERROR_DEADBAND_FRAMES 64.0
#define AO_MAXIMUM_RATE_CORRECTION 0.005
#define AO_RATE_CORRECTION_SMOOTHING_SECONDS 0.5
#define AO_TARGET_QUEUE_SECONDS (2048.0 / 48000.0)

struct AOAudioBridge {
    float *samples;
    uint32_t capacityFrames;
    uint32_t channelCount;
    uint32_t bytesPerSample;
    uint32_t sourceBytesPerFrame;
    bool sourceInterleaved;
    uint32_t gainRampFrames;
    double sourceSampleRate;
    double outputSampleRate;
    double baseSourceFramesPerOutputFrame;
    double renderSourcePosition;
    double renderRateCorrection;
    uint32_t targetQueuedFrames;
    bool renderIsPrimed;
    _Atomic bool resetQueueOnNextRender;
    _Atomic int32_t publishedRateCorrectionMilliPPM;
    _Atomic uint32_t publishedIsPrimed;

    int64_t renderGainQ31;
    int64_t renderTargetGainQ31;
    uint32_t renderGainRampRemainingFrames;
    uint64_t appliedGainRampGeneration;
    _Atomic int32_t requestedGainQ31;
    _Atomic uint32_t requestedGainRampFrames;
    _Atomic uint64_t requestedGainRampGeneration;
    _Atomic int32_t publishedGainQ31;
    _Atomic uint32_t publishedGainRampRemainingFrames;

    _Atomic uint64_t readIndex;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t captureCallbackCount;
    _Atomic uint64_t renderCallbackCount;
    _Atomic uint64_t captureRequestedFrameCount;
    _Atomic uint64_t renderRequestedFrameCount;
    _Atomic uint64_t capturedFrameCount;
    _Atomic uint64_t renderedFrameCount;
    _Atomic uint64_t consumedSourceFrameCount;
    _Atomic uint64_t maximumQueuedFrameCount;
    _Atomic uint64_t underflowCount;
    _Atomic uint64_t underflowFrameCount;
    _Atomic uint64_t overflowCount;
    _Atomic uint64_t overflowFrameCount;
};

static uint32_t AOAudioBridgeTargetQueuedFrames(
    double sourceSampleRate,
    uint32_t capacityFrames
) {
    uint32_t target = (uint32_t)(sourceSampleRate * AO_TARGET_QUEUE_SECONDS);
    const uint32_t capacityLimit = capacityFrames / 4;
    if (capacityLimit > 0 && target > capacityLimit) {
        target = capacityLimit;
    }
    if (target == 0) {
        target = 1;
    }
    return target;
}

static double AOClampDouble(double value, double lower, double upper) {
    return value < lower ? lower : (value > upper ? upper : value);
}

static void AOAtomicStoreMaximum(_Atomic uint64_t *value, uint64_t candidate) {
    uint64_t current = atomic_load_explicit(value, memory_order_relaxed);
    while (candidate > current && !atomic_compare_exchange_weak_explicit(
        value,
        &current,
        candidate,
        memory_order_relaxed,
        memory_order_relaxed
    )) {
    }
}

static bool AOAudioBridgeSupportsFormat(AudioStreamBasicDescription format) {
    const bool isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && format.mBitsPerChannel == 32;
    return isFloatPCM
        && format.mChannelsPerFrame >= 1
        && format.mChannelsPerFrame <= 2
        && format.mBytesPerFrame > 0;
}

AOAudioBridge *AOAudioBridgeCreate(
    AudioStreamBasicDescription format,
    double outputSampleRate,
    uint32_t capacityFrames,
    uint32_t gainRampFrames
) {
    if (!AOAudioBridgeSupportsFormat(format)
        || format.mSampleRate <= 0
        || outputSampleRate <= 0
        || capacityFrames == 0) {
        return NULL;
    }

    AOAudioBridge *bridge = calloc(1, sizeof(AOAudioBridge));
    if (bridge == NULL) {
        return NULL;
    }

    bridge->samples = calloc(
        (size_t)capacityFrames * format.mChannelsPerFrame,
        sizeof(float)
    );
    if (bridge->samples == NULL) {
        free(bridge);
        return NULL;
    }

    bridge->capacityFrames = capacityFrames;
    bridge->channelCount = format.mChannelsPerFrame;
    bridge->bytesPerSample = sizeof(float);
    bridge->sourceBytesPerFrame = format.mBytesPerFrame;
    bridge->sourceInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    bridge->gainRampFrames = gainRampFrames;
    bridge->sourceSampleRate = format.mSampleRate;
    bridge->outputSampleRate = outputSampleRate;
    bridge->baseSourceFramesPerOutputFrame = format.mSampleRate / outputSampleRate;
    bridge->targetQueuedFrames = AOAudioBridgeTargetQueuedFrames(
        format.mSampleRate,
        capacityFrames
    );
    bridge->renderGainQ31 = gainRampFrames > 0 ? 0 : AO_GAIN_UNITY_Q31;
    bridge->renderTargetGainQ31 = AO_GAIN_UNITY_Q31;
    bridge->renderGainRampRemainingFrames = gainRampFrames;
    bridge->appliedGainRampGeneration = gainRampFrames > 0 ? 0 : 1;
    atomic_store_explicit(&bridge->requestedGainQ31, AO_GAIN_UNITY_Q31, memory_order_relaxed);
    atomic_store_explicit(&bridge->requestedGainRampFrames, gainRampFrames, memory_order_relaxed);
    atomic_store_explicit(&bridge->requestedGainRampGeneration, 1, memory_order_relaxed);
    atomic_store_explicit(&bridge->publishedGainQ31, (int32_t)bridge->renderGainQ31, memory_order_relaxed);
    atomic_store_explicit(
        &bridge->publishedGainRampRemainingFrames,
        gainRampFrames,
        memory_order_relaxed
    );
    atomic_store_explicit(&bridge->publishedRateCorrectionMilliPPM, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->publishedIsPrimed, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->resetQueueOnNextRender, false, memory_order_relaxed);
    return bridge;
}

void AOAudioBridgeDestroy(AOAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }
    free(bridge->samples);
    free(bridge);
}

void AOAudioBridgeReset(AOAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }
    atomic_store_explicit(&bridge->readIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->captureCallbackCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderCallbackCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->captureRequestedFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderRequestedFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->capturedFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderedFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->consumedSourceFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->maximumQueuedFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->underflowCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->underflowFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->overflowCount, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->overflowFrameCount, 0, memory_order_relaxed);
    bridge->renderGainQ31 = bridge->gainRampFrames > 0 ? 0 : AO_GAIN_UNITY_Q31;
    bridge->renderTargetGainQ31 = AO_GAIN_UNITY_Q31;
    bridge->renderGainRampRemainingFrames = bridge->gainRampFrames;
    bridge->appliedGainRampGeneration = bridge->gainRampFrames > 0 ? 0 : 1;
    bridge->renderSourcePosition = 0;
    bridge->renderRateCorrection = 0;
    bridge->renderIsPrimed = false;
    atomic_store_explicit(&bridge->requestedGainQ31, AO_GAIN_UNITY_Q31, memory_order_relaxed);
    atomic_store_explicit(
        &bridge->requestedGainRampFrames,
        bridge->gainRampFrames,
        memory_order_relaxed
    );
    atomic_store_explicit(&bridge->requestedGainRampGeneration, 1, memory_order_relaxed);
    atomic_store_explicit(&bridge->publishedGainQ31, (int32_t)bridge->renderGainQ31, memory_order_relaxed);
    atomic_store_explicit(
        &bridge->publishedGainRampRemainingFrames,
        bridge->gainRampFrames,
        memory_order_relaxed
    );
    atomic_store_explicit(&bridge->publishedRateCorrectionMilliPPM, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->publishedIsPrimed, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->resetQueueOnNextRender, false, memory_order_relaxed);
}

void AOAudioBridgeResetQueueWatermark(AOAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }
    const uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    const uint64_t queuedFrames = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    atomic_store_explicit(
        &bridge->maximumQueuedFrameCount,
        queuedFrames,
        memory_order_relaxed
    );
}

void AOAudioBridgePrepareForOutputStart(AOAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }

    // The output consumer must be stopped while this control-plane operation
    // runs. Rebase it now to limit pressure, then arm a second rebase for the
    // first actual hardware callback in case the device starts asynchronously.
    const uint64_t writeIndex = atomic_load_explicit(
        &bridge->writeIndex,
        memory_order_acquire
    );
    atomic_store_explicit(&bridge->readIndex, writeIndex, memory_order_release);
    atomic_store_explicit(&bridge->maximumQueuedFrameCount, 0, memory_order_relaxed);

    bridge->renderSourcePosition = 0;
    bridge->renderRateCorrection = 0;
    bridge->renderIsPrimed = false;
    atomic_store_explicit(&bridge->publishedRateCorrectionMilliPPM, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->publishedIsPrimed, 0, memory_order_release);
    atomic_store_explicit(&bridge->resetQueueOnNextRender, true, memory_order_release);
}

bool AOAudioBridgeConfigureOutputSampleRate(
    AOAudioBridge *bridge,
    double outputSampleRate
) {
    if (bridge == NULL || outputSampleRate <= 0) {
        return false;
    }
    bridge->outputSampleRate = outputSampleRate;
    bridge->baseSourceFramesPerOutputFrame = bridge->sourceSampleRate / outputSampleRate;
    AOAudioBridgePrepareForOutputStart(bridge);
    return true;
}

void AOAudioBridgeBeginGainRamp(
    AOAudioBridge *bridge,
    float targetGain,
    uint32_t durationFrames
) {
    if (bridge == NULL) {
        return;
    }
    const float clampedGain = targetGain < 0.0f
        ? 0.0f
        : (targetGain > 1.0f ? 1.0f : targetGain);
    const int32_t targetQ31 = (int32_t)((double)clampedGain * 2147483647.0);
    atomic_store_explicit(&bridge->requestedGainQ31, targetQ31, memory_order_relaxed);
    atomic_store_explicit(
        &bridge->requestedGainRampFrames,
        durationFrames,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &bridge->requestedGainRampGeneration,
        1,
        memory_order_release
    );
}

static uint32_t AOAudioBridgeInputFrameCount(
    const AOAudioBridge *bridge,
    const AudioBufferList *inputData
) {
    if (inputData->mNumberBuffers == 0) {
        return 0;
    }

    if (bridge->sourceInterleaved) {
        const AudioBuffer *buffer = &inputData->mBuffers[0];
        if (buffer->mData == NULL || bridge->sourceBytesPerFrame == 0) {
            return 0;
        }
        return buffer->mDataByteSize / bridge->sourceBytesPerFrame;
    }

    if (inputData->mNumberBuffers < bridge->channelCount) {
        return 0;
    }

    uint32_t frameCount = UINT32_MAX;
    for (uint32_t channel = 0; channel < bridge->channelCount; channel++) {
        const AudioBuffer *buffer = &inputData->mBuffers[channel];
        if (buffer->mData == NULL) {
            return 0;
        }
        const uint32_t bufferFrames = buffer->mDataByteSize / bridge->bytesPerSample;
        frameCount = bufferFrames < frameCount ? bufferFrames : frameCount;
    }
    return frameCount == UINT32_MAX ? 0 : frameCount;
}

static float AOAudioBridgeInputSample(
    const AOAudioBridge *bridge,
    const AudioBufferList *inputData,
    uint32_t frame,
    uint32_t channel
) {
    if (bridge->sourceInterleaved) {
        const AudioBuffer *buffer = &inputData->mBuffers[0];
        const float *samples = buffer->mData;
        return samples[(size_t)frame * bridge->channelCount + channel];
    }

    const AudioBuffer *buffer = &inputData->mBuffers[channel];
    const float *samples = buffer->mData;
    return samples[frame];
}

void AOAudioBridgeWrite(
    AOAudioBridge *bridge,
    const AudioBufferList *inputData
) {
    if (bridge == NULL || inputData == NULL) {
        return;
    }

    atomic_fetch_add_explicit(&bridge->captureCallbackCount, 1, memory_order_relaxed);

    const uint32_t requestedFrames = AOAudioBridgeInputFrameCount(bridge, inputData);
    if (requestedFrames == 0) {
        return;
    }
    atomic_fetch_add_explicit(
        &bridge->captureRequestedFrameCount,
        requestedFrames,
        memory_order_relaxed
    );

    const uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    const uint64_t queuedFrames = writeIndex - readIndex;
    const uint32_t availableFrames = queuedFrames >= bridge->capacityFrames
        ? 0
        : bridge->capacityFrames - (uint32_t)queuedFrames;
    const uint32_t framesToWrite = requestedFrames < availableFrames
        ? requestedFrames
        : availableFrames;

    for (uint32_t frame = 0; frame < framesToWrite; frame++) {
        const uint32_t ringFrame = (uint32_t)((writeIndex + frame) % bridge->capacityFrames);
        for (uint32_t channel = 0; channel < bridge->channelCount; channel++) {
            bridge->samples[(size_t)ringFrame * bridge->channelCount + channel] =
                AOAudioBridgeInputSample(bridge, inputData, frame, channel);
        }
    }

    atomic_store_explicit(
        &bridge->writeIndex,
        writeIndex + framesToWrite,
        memory_order_release
    );
    atomic_fetch_add_explicit(
        &bridge->capturedFrameCount,
        framesToWrite,
        memory_order_relaxed
    );
    AOAtomicStoreMaximum(&bridge->maximumQueuedFrameCount, queuedFrames + framesToWrite);

    if (framesToWrite < requestedFrames) {
        atomic_fetch_add_explicit(&bridge->overflowCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &bridge->overflowFrameCount,
            requestedFrames - framesToWrite,
            memory_order_relaxed
        );
    }
}

OSStatus AOAudioBridgeCaptureIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;

    AOAudioBridge *bridge = inClientData;
    if (bridge == NULL) {
        return kAudio_ParamError;
    }
    AOAudioBridgeWrite(bridge, inInputData);
    return noErr;
}

static void AOAudioBridgeClearOutput(AudioBufferList *outputData) {
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; bufferIndex++) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static void AOAudioBridgeSetOutputSample(
    AudioBufferList *outputData,
    uint32_t frame,
    uint32_t channel,
    float sample
) {
    if (outputData->mNumberBuffers == 1) {
        AudioBuffer *buffer = &outputData->mBuffers[0];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            return;
        }
        float *samples = buffer->mData;
        const uint32_t outputChannels = buffer->mNumberChannels;
        if (channel < outputChannels) {
            samples[(size_t)frame * outputChannels + channel] = sample;
        }
        return;
    }

    if (channel >= outputData->mNumberBuffers) {
        return;
    }
    AudioBuffer *buffer = &outputData->mBuffers[channel];
    if (buffer->mData != NULL) {
        float *samples = buffer->mData;
        samples[frame] = sample;
    }
}

OSStatus AOAudioBridgeRender(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)inTimeStamp;
    (void)inBusNumber;

    AOAudioBridge *bridge = inRefCon;
    if (bridge == NULL || ioData == NULL) {
        return kAudio_ParamError;
    }

    atomic_fetch_add_explicit(&bridge->renderCallbackCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &bridge->renderRequestedFrameCount,
        inNumberFrames,
        memory_order_relaxed
    );
    AOAudioBridgeClearOutput(ioData);

    const uint64_t requestedRampGeneration = atomic_load_explicit(
        &bridge->requestedGainRampGeneration,
        memory_order_acquire
    );
    if (requestedRampGeneration != bridge->appliedGainRampGeneration) {
        bridge->renderTargetGainQ31 = atomic_load_explicit(
            &bridge->requestedGainQ31,
            memory_order_relaxed
        );
        bridge->renderGainRampRemainingFrames = atomic_load_explicit(
            &bridge->requestedGainRampFrames,
            memory_order_relaxed
        );
        bridge->appliedGainRampGeneration = requestedRampGeneration;
        if (bridge->renderGainRampRemainingFrames == 0) {
            bridge->renderGainQ31 = bridge->renderTargetGainQ31;
        }
    }

    if (atomic_exchange_explicit(
        &bridge->resetQueueOnNextRender,
        false,
        memory_order_acq_rel
    )) {
        // Some external devices return from AudioOutputUnitStart before their
        // hardware callback begins. Drop everything accumulated through this
        // first actual callback so the replacement primes from current audio,
        // not from a delayed handoff backlog.
        const uint64_t firstRenderWriteIndex = atomic_load_explicit(
            &bridge->writeIndex,
            memory_order_acquire
        );
        atomic_store_explicit(
            &bridge->readIndex,
            firstRenderWriteIndex,
            memory_order_release
        );
        atomic_store_explicit(
            &bridge->maximumQueuedFrameCount,
            0,
            memory_order_relaxed
        );
        bridge->renderSourcePosition = 0;
        bridge->renderRateCorrection = 0;
        bridge->renderIsPrimed = false;
        atomic_store_explicit(
            &bridge->publishedGainQ31,
            (int32_t)bridge->renderGainQ31,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &bridge->publishedGainRampRemainingFrames,
            bridge->renderGainRampRemainingFrames,
            memory_order_release
        );
        atomic_store_explicit(
            &bridge->publishedRateCorrectionMilliPPM,
            0,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &bridge->publishedIsPrimed,
            0,
            memory_order_release
        );
        if (ioActionFlags != NULL) {
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }

    const uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_relaxed);
    const uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    const uint64_t queuedFrames = writeIndex - readIndex;
    const double nominalSourceFramesForCallback = bridge->baseSourceFramesPerOutputFrame
        * inNumberFrames;
    uint64_t primingRequirement = bridge->targetQueuedFrames
        + (uint64_t)nominalSourceFramesForCallback + 2;
    if (primingRequirement > bridge->capacityFrames) {
        primingRequirement = bridge->targetQueuedFrames;
    }
    if (!bridge->renderIsPrimed && queuedFrames >= primingRequirement) {
        bridge->renderIsPrimed = true;
        bridge->renderSourcePosition = 0;
    }

    if (bridge->renderIsPrimed) {
        const double projectedQueuedFrames = (double)queuedFrames
            - nominalSourceFramesForCallback;
        double queueError = projectedQueuedFrames - bridge->targetQueuedFrames;
        if (queueError > -AO_QUEUE_ERROR_DEADBAND_FRAMES
            && queueError < AO_QUEUE_ERROR_DEADBAND_FRAMES) {
            queueError = 0;
        }
        const double desiredCorrection = AOClampDouble(
            queueError * AO_QUEUE_CORRECTION_PPM_PER_FRAME / 1000000.0,
            -AO_MAXIMUM_RATE_CORRECTION,
            AO_MAXIMUM_RATE_CORRECTION
        );
        const double callbackSeconds = bridge->outputSampleRate > 0
            ? inNumberFrames / bridge->outputSampleRate
            : 0;
        const double smoothing = AOClampDouble(
            callbackSeconds / AO_RATE_CORRECTION_SMOOTHING_SECONDS,
            0,
            1
        );
        bridge->renderRateCorrection += smoothing
            * (desiredCorrection - bridge->renderRateCorrection);
    }

    const double sourceFramesPerOutputFrame = bridge->baseSourceFramesPerOutputFrame
        * (1.0 + bridge->renderRateCorrection);
    uint32_t renderedOutputFrames = 0;
    double sourcePosition = bridge->renderSourcePosition;
    for (uint32_t frame = 0; frame < inNumberFrames; frame++) {
        const bool shouldAdvanceGain = bridge->renderIsPrimed
            || bridge->renderTargetGainQ31 == 0;
        if (shouldAdvanceGain && bridge->renderGainRampRemainingFrames > 0) {
            bridge->renderGainQ31 += (
                bridge->renderTargetGainQ31 - bridge->renderGainQ31
            ) / bridge->renderGainRampRemainingFrames;
            bridge->renderGainRampRemainingFrames -= 1;
        }

        if (!bridge->renderIsPrimed) {
            continue;
        }

        const uint64_t sourceOffset = (uint64_t)sourcePosition;
        const double fraction = sourcePosition - sourceOffset;
        const uint64_t requiredFrames = sourceOffset + (fraction > 0.000000001 ? 2 : 1);
        if (requiredFrames > queuedFrames) {
            continue;
        }

        const uint32_t firstRingFrame = (uint32_t)(
            (readIndex + sourceOffset) % bridge->capacityFrames
        );
        const uint32_t secondRingFrame = (uint32_t)(
            (readIndex + sourceOffset + 1) % bridge->capacityFrames
        );
        const float gain = (float)((double)bridge->renderGainQ31 / 2147483647.0);
        for (uint32_t channel = 0; channel < bridge->channelCount; channel++) {
            const float first = bridge->samples[
                (size_t)firstRingFrame * bridge->channelCount + channel
            ];
            const float sample = fraction > 0.000000001
                ? first + (bridge->samples[
                    (size_t)secondRingFrame * bridge->channelCount + channel
                ] - first) * (float)fraction
                : first;
            AOAudioBridgeSetOutputSample(ioData, frame, channel, sample * gain);
        }
        renderedOutputFrames += 1;
        sourcePosition += sourceFramesPerOutputFrame;
    }

    uint64_t consumedSourceFrames = (uint64_t)sourcePosition;
    if (consumedSourceFrames > queuedFrames) {
        consumedSourceFrames = queuedFrames;
    }
    bridge->renderSourcePosition = sourcePosition - consumedSourceFrames;

    const bool wasPrimed = bridge->renderIsPrimed;
    const bool didUnderflow = wasPrimed && renderedOutputFrames < inNumberFrames;
    if (didUnderflow) {
        // Discard a possible fractional tail and re-prime from fresh captured
        // audio instead of interpolating across a pause or discontinuity.
        atomic_store_explicit(&bridge->readIndex, writeIndex, memory_order_release);
        bridge->renderSourcePosition = 0;
        bridge->renderRateCorrection = 0;
        bridge->renderIsPrimed = false;
    } else {
        atomic_store_explicit(
            &bridge->readIndex,
            readIndex + consumedSourceFrames,
            memory_order_release
        );
    }

    atomic_store_explicit(
        &bridge->publishedGainQ31,
        (int32_t)bridge->renderGainQ31,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->publishedGainRampRemainingFrames,
        bridge->renderGainRampRemainingFrames,
        memory_order_release
    );
    atomic_store_explicit(
        &bridge->publishedRateCorrectionMilliPPM,
        (int32_t)(bridge->renderRateCorrection * 1000000000.0),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->publishedIsPrimed,
        bridge->renderIsPrimed ? 1 : 0,
        memory_order_release
    );
    atomic_fetch_add_explicit(
        &bridge->renderedFrameCount,
        renderedOutputFrames,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &bridge->consumedSourceFrameCount,
        consumedSourceFrames,
        memory_order_relaxed
    );

    if (didUnderflow) {
        atomic_fetch_add_explicit(&bridge->underflowCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &bridge->underflowFrameCount,
            inNumberFrames - renderedOutputFrames,
            memory_order_relaxed
        );
    }
    if (renderedOutputFrames == 0 && ioActionFlags != NULL) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}

AOAudioBridgeSnapshot AOAudioBridgeRead(const AOAudioBridge *bridge) {
    AOAudioBridgeSnapshot snapshot = {0};
    if (bridge == NULL) {
        return snapshot;
    }

    const uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    snapshot.captureCallbackCount = atomic_load_explicit(
        &bridge->captureCallbackCount,
        memory_order_relaxed
    );
    snapshot.renderCallbackCount = atomic_load_explicit(
        &bridge->renderCallbackCount,
        memory_order_relaxed
    );
    snapshot.captureRequestedFrameCount = atomic_load_explicit(
        &bridge->captureRequestedFrameCount,
        memory_order_relaxed
    );
    snapshot.renderRequestedFrameCount = atomic_load_explicit(
        &bridge->renderRequestedFrameCount,
        memory_order_relaxed
    );
    snapshot.capturedFrameCount = atomic_load_explicit(
        &bridge->capturedFrameCount,
        memory_order_relaxed
    );
    snapshot.renderedFrameCount = atomic_load_explicit(
        &bridge->renderedFrameCount,
        memory_order_relaxed
    );
    snapshot.consumedSourceFrameCount = atomic_load_explicit(
        &bridge->consumedSourceFrameCount,
        memory_order_relaxed
    );
    snapshot.queuedFrameCount = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    snapshot.maximumQueuedFrameCount = atomic_load_explicit(
        &bridge->maximumQueuedFrameCount,
        memory_order_relaxed
    );
    snapshot.underflowCount = atomic_load_explicit(
        &bridge->underflowCount,
        memory_order_relaxed
    );
    snapshot.underflowFrameCount = atomic_load_explicit(
        &bridge->underflowFrameCount,
        memory_order_relaxed
    );
    snapshot.overflowCount = atomic_load_explicit(
        &bridge->overflowCount,
        memory_order_relaxed
    );
    snapshot.overflowFrameCount = atomic_load_explicit(
        &bridge->overflowFrameCount,
        memory_order_relaxed
    );
    snapshot.capacityFrameCount = bridge->capacityFrames;
    snapshot.targetQueuedFrameCount = bridge->targetQueuedFrames;
    snapshot.isPrimed = atomic_load_explicit(
        &bridge->publishedIsPrimed,
        memory_order_acquire
    );
    snapshot.sourceSampleRate = bridge->sourceSampleRate;
    snapshot.outputSampleRate = bridge->outputSampleRate;
    snapshot.rateCorrectionPPM = (float)atomic_load_explicit(
        &bridge->publishedRateCorrectionMilliPPM,
        memory_order_relaxed
    ) / 1000.0f;
    snapshot.gainRampRemainingFrameCount = atomic_load_explicit(
        &bridge->publishedGainRampRemainingFrames,
        memory_order_acquire
    );
    snapshot.currentGain = (float)atomic_load_explicit(
        &bridge->publishedGainQ31,
        memory_order_relaxed
    ) / 2147483647.0f;
    return snapshot;
}
