cmake_minimum_required(VERSION 3.5.0)
project(gemini_live_translate_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(entry SHARED AudioPlaybackCapture.cpp)
target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libohaudio.so
    libhilog_ndk.z.so
    libnative_avscreen_capture.so
    libnative_media_core.so
)

