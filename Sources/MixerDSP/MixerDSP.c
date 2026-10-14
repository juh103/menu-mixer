#include "MixerDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stddef.h>

struct MixerDSP {
    _Atomic(float) target;
    _Atomic(unsigned long) callbacks;
    float current;
    unsigned inputOffset;
};

MixerDSP *MixerDSPCreate(float gain) {
    MixerDSP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->target, gain);
    atomic_init(&s->callbacks, 0);
    s->current = gain;
    return s;
}
void MixerDSPDestroy(MixerDSP *s) { free(s); }
void MixerDSPSetGain(MixerDSP *s, float gain) {
    if (!isfinite(gain)) gain = 0;
    atomic_store_explicit(&s->target, fmaxf(0, fminf(1, gain)), memory_order_relaxed);
}
// Set only before AudioDeviceStart; never mutated during a callback.
void MixerDSPSetInputOffset(MixerDSP *s, unsigned channels) { s->inputOffset = channels; }
unsigned long MixerDSPCallbackCount(MixerDSP *s) {
    return atomic_load_explicit(&s->callbacks, memory_order_relaxed);
}
AudioDeviceIOProc MixerDSPGetRenderCallback(void) { return MixerDSPRender; }

OSStatus MixerDSPUseTapInputs(AudioObjectID device, AudioDeviceIOProcID proc,
                             unsigned physicalStreams, unsigned totalStreams) {
    if (!physicalStreams) return noErr;
    if (physicalStreams >= totalStreams) return kAudioHardwareIllegalOperationError;
    UInt32 size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn)
                           + totalStreams * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = totalStreams;
    for (unsigned i = physicalStreams; i < totalStreams; i++) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    if (status == noErr) {
        // Verify hardware microphone streams stay disabled before starting IO.
        status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, usage);
        if (status == noErr && usage->mNumberStreams != totalStreams)
            status = kAudioHardwareIllegalOperationError;
        if (status == noErr) {
            for (unsigned i = 0; i < totalStreams; i++) {
                if ((usage->mStreamIsOn[i] != 0) != (i >= physicalStreams))
                    status = kAudioHardwareIllegalOperationError;
            }
        }
    }
    free(usage);
    return status;
}

// Float32 PCM only, verified by the caller. Supports planar and interleaved buffers.
// No allocation, locks, Objective-C, Swift ARC, or logging on the audio thread.
OSStatus MixerDSPRender(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    MixerDSP *s = context;
    if (!s || !output) return noErr;
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    const float target = atomic_load_explicit(&s->target, memory_order_relaxed);
    unsigned outputChannel = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *dst = &output->mBuffers[b];
        if (dst->mData) memset(dst->mData, 0, dst->mDataByteSize);
        for (unsigned c = 0; c < dst->mNumberChannels; c++, outputChannel++) {
            // This prototype routes the first mono/stereo stream only.
            if (outputChannel >= 2 || !input || !dst->mData) continue;
            unsigned wanted = s->inputOffset + outputChannel;
            const AudioBuffer *src = NULL;
            unsigned sourceChannel = wanted;
            for (UInt32 i = 0; i < input->mNumberBuffers; i++) {
                if (sourceChannel < input->mBuffers[i].mNumberChannels) {
                    src = &input->mBuffers[i]; break;
                }
                sourceChannel -= input->mBuffers[i].mNumberChannels;
            }
            if (!src || !src->mData || !src->mNumberChannels) continue;
            unsigned frames = dst->mDataByteSize / (sizeof(float) * dst->mNumberChannels);
            unsigned available = src->mDataByteSize / (sizeof(float) * src->mNumberChannels);
            if (frames > available) frames = available;
            const float *in = src->mData;
            float *out = dst->mData;
            // Ramp across this block to suppress slider/mute clicks.
            for (unsigned f = 0; f < frames; f++) {
                float gain = s->current + (target - s->current) * (float)(f + 1) / frames;
                out[f * dst->mNumberChannels + c] = in[f * src->mNumberChannels + sourceChannel] * gain;
            }
        }
    }
    s->current = target;
    return noErr;
}
