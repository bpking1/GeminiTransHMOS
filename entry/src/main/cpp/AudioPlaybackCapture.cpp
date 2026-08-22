#include "napi/native_api.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "GeminiLiveNative"

namespace {

constexpr int32_t SAMPLE_RATE = 48000;
constexpr int32_t CHANNEL_COUNT = 2;
constexpr size_t RING_CAPACITY = 48000 * 2 * 2 * 2; // Two seconds of stereo PCM16.

enum CaptureState : int32_t {
    IDLE = 0,
    WAITING_AUTHORIZATION = 1,
    RUNNING = 2,
    NOT_AUTHORIZED = 3,
    FAILED = 4,
};

std::mutex g_captureMutex;
OH_AVScreenCapture* g_screenCapture = nullptr;
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

void OnScreenCaptureBufferAvailable(OH_AVScreenCapture* capture, OH_AVBuffer* buffer,
    OH_AVScreenCaptureBufferType bufferType, int64_t timestamp, void* userData)
{
    if (buffer == nullptr) {
        return;
    }

    if (bufferType == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER) {
        if (g_state.load() == WAITING_AUTHORIZATION) {
            g_state.store(RUNNING);
            OH_LOG_INFO(LOG_APP, "OnScreenCaptureBufferAvailable: received inner audio stream, state -> RUNNING");
        }
        uint8_t* addr = OH_AVBuffer_GetAddr(buffer);
        OH_AVCodecBufferAttr attr;
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && addr != nullptr && attr.size > 0) {
            PushRing(addr + attr.offset, static_cast<size_t>(attr.size));
        }
    }
}

void OnScreenCaptureError(OH_AVScreenCapture* capture, int32_t errorCode, void* userData)
{
    OH_LOG_ERROR(LOG_APP, "OnScreenCaptureError callback received: errorCode=%{public}d", errorCode);
    if (errorCode == AV_SCREEN_CAPTURE_ERR_OPERATE_NOT_PERMIT) {
        g_state.store(NOT_AUTHORIZED);
    } else {
        g_state.store(FAILED);
    }
}

void OnScreenCaptureStateChange(OH_AVScreenCapture* capture, OH_AVScreenCaptureStateCode stateCode, void* userData)
{
    OH_LOG_INFO(LOG_APP, "OnScreenCaptureStateChange callback received: stateCode=%{public}d", static_cast<int>(stateCode));
    if (stateCode == OH_SCREEN_CAPTURE_STATE_STARTED) {
        g_state.store(RUNNING);
    } else if (stateCode == OH_SCREEN_CAPTURE_STATE_CANCELED) {
        g_state.store(NOT_AUTHORIZED);
    } else if (stateCode == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL || stateCode == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER) {
        g_state.store(IDLE);
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
    OH_LOG_INFO(LOG_APP, "StartPlaybackCapture called (using AVScreenCapture)");
    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        if (g_screenCapture != nullptr) {
            OH_LOG_WARN(LOG_APP, "StartPlaybackCapture: screen capture already running");
            return CreateInt(env, -2);
        }
    }

    ResetRing();
    g_state.store(WAITING_AUTHORIZATION);

    OH_AVScreenCapture* capture = OH_AVScreenCapture_Create();
    if (capture == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_AVScreenCapture_Create failed");
        g_state.store(FAILED);
        return CreateInt(env, -1);
    }

    OH_AVScreenCapture_SetDataCallback(capture, OnScreenCaptureBufferAvailable, nullptr);
    OH_AVScreenCapture_SetErrorCallback(capture, OnScreenCaptureError, nullptr);
    OH_AVScreenCapture_SetStateCallback(capture, OnScreenCaptureStateChange, nullptr);

    OH_AVScreenCaptureConfig config;
    std::memset(&config, 0, sizeof(config));
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;

    config.audioInfo.innerCapInfo.audioSampleRate = SAMPLE_RATE;
    config.audioInfo.innerCapInfo.audioChannels = CHANNEL_COUNT;
    config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;

    config.videoInfo.videoCapInfo.videoFrameWidth = 720;
    config.videoInfo.videoCapInfo.videoFrameHeight = 1280;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;

    int32_t initRes = OH_AVScreenCapture_Init(capture, config);
    OH_LOG_INFO(LOG_APP, "OH_AVScreenCapture_Init result=%{public}d", initRes);
    if (initRes != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "OH_AVScreenCapture_Init failed: %{public}d", initRes);
        OH_AVScreenCapture_Release(capture);
        g_state.store(FAILED);
        return CreateInt(env, initRes);
    }

    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        g_screenCapture = capture;
    }

    int32_t startRes = OH_AVScreenCapture_StartScreenCapture(capture);
    OH_LOG_INFO(LOG_APP, "OH_AVScreenCapture_StartScreenCapture result=%{public}d", startRes);
    if (startRes != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "OH_AVScreenCapture_StartScreenCapture failed: %{public}d", startRes);
        {
            std::lock_guard<std::mutex> lock(g_captureMutex);
            g_screenCapture = nullptr;
        }
        OH_AVScreenCapture_Release(capture);
        g_state.store(FAILED);
        return CreateInt(env, startRes);
    }

    return CreateInt(env, 0);
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
    OH_LOG_INFO(LOG_APP, "StopPlaybackCapture called");
    OH_AVScreenCapture* capture = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_captureMutex);
        capture = g_screenCapture;
        g_screenCapture = nullptr;
    }

    if (capture != nullptr) {
        OH_AVScreenCapture_StopScreenCapture(capture);
        OH_AVScreenCapture_Release(capture);
    }

    g_state.store(IDLE);
    ResetRing();
    return CreateInt(env, 0);
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
