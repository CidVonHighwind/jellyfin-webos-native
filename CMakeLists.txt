cmake_minimum_required(VERSION 3.18)
project(webos-native LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

include(WebOSTarget)
include(WebOSPackage)
include(Assets)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# C++ exists here for exactly one translation unit: the StarfishMediaAPIs shim.
# C++11 because webOS 3 and older ship libstdc++ 6.0.19 (GCC 4.8).
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif ()

add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# The TV's userland is soft-float *ABI* on a real FPU. softfp keeps the ABI and still
# emits VFP/NEON for the arithmetic - which is why the glyph rasteriser needs no special
# handling here, unlike the Zig build this replaces. See docs/device.md.
if (TARGET_WEBOS AND TARGET_WEBOS_ARCH STREQUAL "arm")
    add_compile_options(-mcpu=cortex-a55 -mfpu=neon-vfpv4 -mfloat-abi=softfp)
endif ()

# A deliberately small target FFmpeg build, shipped beside the app: the TV has no FFmpeg
# a native app may link.
set(FFMPEG_ROOT "/opt/arm-webos-linux-gnueabi_sdk-buildroot/arm-webos-linux-gnueabi/sysroot/usr/local/ffmpeg"
        CACHE PATH "Target FFmpeg prefix")
set(FFMPEG_SONAMES libavformat.so.63 libavcodec.so.63 libavutil.so.61 libswresample.so.7)

add_subdirectory(src)
if (NOT TARGET_WEBOS)
    enable_testing()
    add_subdirectory(tests)
endif ()
