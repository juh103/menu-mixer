#pragma once
#include <CoreAudio/CoreAudio.h>

typedef struct MixerDSP MixerDSP;
MixerDSP *MixerDSPCreate(float gain);
void MixerDSPDestroy(MixerDSP *state);
void MixerDSPSetGain(MixerDSP *state, float gain);
void MixerDSPSetInputOffset(MixerDSP *state, unsigned channels);
unsigned long MixerDSPCallbackCount(MixerDSP *state);
AudioDeviceIOProc MixerDSPGetRenderCallback(void);
OSStatus MixerDSPUseTapInputs(AudioObjectID device, AudioDeviceIOProcID proc,
                             unsigned physicalStreams, unsigned totalStreams);
OSStatus MixerDSPRender(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
