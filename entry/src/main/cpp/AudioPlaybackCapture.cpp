#include "napi/native_api.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#include <hilog/log.h>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "GeminiLiveNative"

namespace {

constexpr int32_t SAMPLE_RATE = 48000;
constexpr int32_t CHANNEL_COUNT = 2;
constexpr uint32_t CAPTURE_MODE = AUDIOSTREAM_PLAYBACKCAPTURE_MODE_MEDIA |
    AUDIOSTREAM_PLAYBACKCAPTURE_MODE_EXCLUDING_SELF;
constexpr size_t RING_CAPACITY = 48000 * 2 * 2 * 2; // Two seconds of stereo PCM16.

enum CaptureState : int32_t {
    IDLE = 0,
    WAITING_AUTHORIZATION = 1,
    RUNNING = 2,
    NOT_AUTHORIZED = 3,
    FAILED = 4,
};

std::mutex g_captureMutex;
OH_AudioCapturer* g_capturer = nullptr;
std::atomic<int32_t> g_state{IDLE};

std::mutex g_ringMutex;
std::vector<uint8_t> g_ring(RING_CAPACITY);
size_t g_ringHead = 0;
size_t g_ringSize = 0;

void ResetRing()
{
    std::lock_guard<std::mutex> lock(g_ringMutex);
    g_ringHead = 0;
    g_ringSize = 0;
}

void PushRing(const uint8_t* input, size_t length)
{
    if (input == nullptr || length == 0) {
        return;
    }

    std::lock_guard<std::mutex> lock(g_ringMutex);
    if (length >= RING_CAPACITY) {
        input += length - RING_CAPACITY;
        length = RING_CAPACITY;
        g_ringHead = 0;
        g_ringSize = 0;
    }

    size_t overflow = g_ringSize + length > RING_CAPACITY
        ? g_ringSize + length - RING_CAPACITY
        : 0;
    if (overflow > 0) {
        g_ringHead = (g_ringHead + overflow) % RING_CAPACITY;
        g_ringSize -= overflow;
    }

    size_t tail = (g_ringHead + g_ringSize) % RING_CAPACITY;
    size_t first = std::min(length, RING_CAPACITY - tail);
    std::memcpy(g_ring.data() + tail, input, first);
    if (first < length) {
        std::memcpy(g_ring.data(), input + first, length - first);
    }
    g_ringSize += length;
}

size_t PopRing(uint8_t* output, size_t requested)
{
    std::lock_guard<std::mutex> lock(g_ringMutex);
    // Twelve input bytes are exactly one 16 kHz mono sample after 48 kHz
    // stereo downmixing. Keeping this alignment avoids boundary artifacts.
    size_t length = std::min(requested, g_ringSize);
    length -= length % 12;
    if (length == 0) {
        return 0;
    }

    size_t first = std::min(length, RING_CAPACITY - g_ringHead);
    std::memcpy(output, g_ring.data() + g_ringHead, first);
    if (first < length) {
        std::memcpy(output + first, g_ring.data(), length - first);
    }
    g_ringHead = (g_ringHead + length) % RING_CAPACITY;
    g_ringSize -= length;
    return length;
}

void OnPlaybackData(OH_AudioCapturer*, void*, void* audioData, int32_t audioDataSize)
{
    if (g_state.load() != RUNNING || audioData == nullptr || audioDataSize <= 0) {
        return;
    }
    PushRing(static_cast<uint8_t*>(audioData), static_cast<size_t>(audioDataSize));
}

void OnPlaybackCaptureStarted(OH_AudioCapturer* capturer, void*,
    OH_AudioStream_PlaybackCaptureStartState state)
{
    OH_LOG_INFO(LOG_APP, "OnPlaybackCaptureStarted callback received: state=%{public}d (0=SUCCESS, 1=FAILED, 2=NOT_AUTHORIZED)",
        static_cast<int>(state));
    OH_AudioCapturer* toRelease = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        // The user can cancel while the system authorization sheet is open.
        // Ignore a late callback if this capturer has already been released.
        if (g_capturer != capturer || g_state.load() != WAITING_AUTHORIZATION) {
            OH_LOG_WARN(LOG_APP, "OnPlaybackCaptureStarted: capturer mismatch or not waiting");
            return;
        }
        if (state == AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_SUCCESS) {
            OH_LOG_INFO(LOG_APP, "OnPlaybackCaptureStarted: successfully started playback capture!");
            g_state.store(RUNNING);
            return;
        }
        g_state.store(state == AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_NOT_AUTHORIZED
            ? NOT_AUTHORIZED
            : FAILED);
        toRelease = g_capturer;
        g_capturer = nullptr;
    }
    if (toRelease != nullptr) {
        OH_LOG_WARN(LOG_APP, "OnPlaybackCaptureStarted: releasing capturer due to state=%{public}d", static_cast<int>(state));
        OH_AudioCapturer_Release(toRelease);
    }
}

napi_value CreateInt(napi_env env, int32_t value)
{
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value StartPlaybackCapture(napi_env env, napi_callback_info)
{
    OH_LOG_INFO(LOG_APP, "StartPlaybackCapture called");
    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        if (g_capturer != nullptr) {
            OH_LOG_WARN(LOG_APP, "StartPlaybackCapture: capturer already exists");
            return CreateInt(env, -2);
        }
    }

    ResetRing();
    g_state.store(WAITING_AUTHORIZATION);

    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER);
    if (result != AUDIOSTREAM_SUCCESS || builder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_AudioStreamBuilder_Create failed: %{public}d", static_cast<int>(result));
        g_state.store(FAILED);
        return CreateInt(env, static_cast<int32_t>(result));
    }

    result = OH_AudioStreamBuilder_SetSamplingRate(builder, SAMPLE_RATE);
    if (result == AUDIOSTREAM_SUCCESS) {
        result = OH_AudioStreamBuilder_SetChannelCount(builder, CHANNEL_COUNT);
    }
    if (result == AUDIOSTREAM_SUCCESS) {
        result = OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    }
    if (result == AUDIOSTREAM_SUCCESS) {
        result = OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    }
    if (result == AUDIOSTREAM_SUCCESS) {
        result = OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, OnPlaybackData, nullptr);
    }
    if (result == AUDIOSTREAM_SUCCESS) {
        result = OH_AudioStreamBuilder_SetPlaybackCaptureMode(builder, CAPTURE_MODE);
    }
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "OH_AudioStreamBuilder configuration failed: %{public}d", static_cast<int>(result));
        OH_AudioStreamBuilder_Destroy(builder);
        g_state.store(FAILED);
        return CreateInt(env, static_cast<int32_t>(result));
    }

    OH_AudioCapturer* capturer = nullptr;
    result = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer);
    OH_AudioStreamBuilder_Destroy(builder);
    if (result != AUDIOSTREAM_SUCCESS || capturer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_AudioStreamBuilder_GenerateCapturer failed: %{public}d", static_cast<int>(result));
        g_state.store(FAILED);
        return CreateInt(env, static_cast<int32_t>(result));
    }

    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        g_capturer = capturer;
    }

    OH_LOG_INFO(LOG_APP, "Requesting Playback Capture Start...");
    result = OH_AudioCapturer_RequestPlaybackCaptureStart(
        capturer, OnPlaybackCaptureStarted, nullptr);
    OH_LOG_INFO(LOG_APP, "OH_AudioCapturer_RequestPlaybackCaptureStart returned: %{public}d", static_cast<int>(result));
    if (result != AUDIOSTREAM_SUCCESS) {
        bool shouldRelease = false;
        {
            std::lock_guard<std::mutex> lock(g_captureMutex);
            if (g_capturer == capturer) {
                g_capturer = nullptr;
                shouldRelease = true;
            }
        }
        if (shouldRelease) {
            OH_AudioCapturer_Release(capturer);
        }
        g_state.store(FAILED);
    }
    return CreateInt(env, static_cast<int32_t>(result));
}

napi_value GetPlaybackCaptureState(napi_env env, napi_callback_info)
{
    return CreateInt(env, g_state.load());
}

napi_value ReadPlaybackPcm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t requested = 19200;
    if (argc == 1) {
        napi_get_value_uint32(env, args[0], &requested);
    }
    requested = std::min<uint32_t>(requested, static_cast<uint32_t>(RING_CAPACITY));
    requested -= requested % 12;

    std::vector<uint8_t> temporary(requested);
    size_t length = PopRing(temporary.data(), temporary.size());

    void* output = nullptr;
    napi_value arrayBuffer;
    napi_create_arraybuffer(env, length, &output, &arrayBuffer);
    if (length > 0 && output != nullptr) {
        std::memcpy(output, temporary.data(), length);
    }
    return arrayBuffer;
}

napi_value StopPlaybackCapture(napi_env env, napi_callback_info)
{
    OH_AudioCapturer* capturer = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        capturer = g_capturer;
        g_capturer = nullptr;
    }

    int32_t resultCode = 0;
    if (capturer != nullptr) {
        OH_AudioStream_Result stopResult = OH_AudioCapturer_Stop(capturer);
        OH_AudioStream_Result releaseResult = OH_AudioCapturer_Release(capturer);
        resultCode = stopResult != AUDIOSTREAM_SUCCESS
            ? static_cast<int32_t>(stopResult)
            : static_cast<int32_t>(releaseResult);
    }
    g_state.store(IDLE);
    ResetRing();
    return CreateInt(env, resultCode);
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"startPlaybackCapture", nullptr, StartPlaybackCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPlaybackCaptureState", nullptr, GetPlaybackCaptureState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readPlaybackPcm", nullptr, ReadPlaybackPcm, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopPlaybackCapture", nullptr, StopPlaybackCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule()
{
    napi_module_register(&module);
}
