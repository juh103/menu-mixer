#include "MixerDSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void closeTo(float actual, float expected) {
    assert(fabsf(actual - expected) < 0.00001f);
}
static void render(MixerDSP *s, const AudioBufferList *in, AudioBufferList *out) {
    assert(MixerDSPRender(0, NULL, in, NULL, out, NULL, s) == noErr);
}
int main(void) {
    // Interleaved stereo attenuation and channel separation.
    float input[] = {1, -1, 0.5, -0.5, 0.25, -0.25, 0, 0};
    float output[8];
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    MixerDSP *s = MixerDSPCreate(0.5);
    assert(s);
    render(s, &in, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], input[i] * 0.5f);
    assert(MixerDSPCallbackCount(s) == 1);
    // Mute ramps to zero within one buffer, then stays exactly silent.
    MixerDSPSetGain(s, 0);
    render(s, &in, &out);
    closeTo(output[0], 0.375f);
    closeTo(output[1], -0.375f);
    closeTo(output[6], 0);
    render(s, &in, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], 0);
    // Gain cannot amplify above 100%, including invalid inputs.
    MixerDSPSetGain(s, 9);
    render(s, &in, &out);
    render(s, &in, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], input[i]);
    MixerDSPSetGain(s, NAN);
    render(s, &in, &out);
    render(s, &in, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], 0);
    MixerDSPDestroy(s);

    // Planar stereo input to interleaved output, short buffers zero padded.
    struct { UInt32 count; AudioBuffer buffers[2]; } planar;
    float left[] = {1, 0.5}, right[] = {-1, -0.5};
    planar.count = 2;
    planar.buffers[0] = (AudioBuffer){1, sizeof(left), left};
    planar.buffers[1] = (AudioBuffer){1, sizeof(right), right};
    s = MixerDSPCreate(1);
    render(s, (AudioBufferList *)&planar, &out);
    closeTo(output[0], 1); closeTo(output[1], -1);
    closeTo(output[2], 0.5); closeTo(output[3], -0.5);
    for (unsigned i = 4; i < 8; i++) closeTo(output[i], 0);
    // Interleaved input to planar output.
    float outLeft[4], outRight[4];
    struct { UInt32 count; AudioBuffer buffers[2]; } planarOut;
    planarOut.count = 2;
    planarOut.buffers[0] = (AudioBuffer){1, sizeof(outLeft), outLeft};
    planarOut.buffers[1] = (AudioBuffer){1, sizeof(outRight), outRight};
    render(s, &in, (AudioBufferList *)&planarOut);
    for (unsigned i = 0; i < 4; i++) {
        closeTo(outLeft[i], input[2*i]); closeTo(outRight[i], input[2*i+1]);
    }
    // Missing input must clear all old output samples.
    render(s, NULL, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], 0);
    // Disabled microphone buffers retain leading channel slots with NULL data.
    struct { UInt32 count; AudioBuffer buffers[2]; } duplex;
    duplex.count = 2;
    duplex.buffers[0] = (AudioBuffer){1, 0, NULL};
    duplex.buffers[1] = in.mBuffers[0];
    MixerDSPSetInputOffset(s, 1);
    render(s, (AudioBufferList *)&duplex, &out);
    for (unsigned i = 0; i < 8; i++) closeTo(output[i], input[i]);
    MixerDSPDestroy(s);
    puts("PASS: attenuation, stereo mapping, mute ramp, gain bounds, planar/interleaved conversion, short/missing buffers, disabled microphone offset");
}
