cmake_minimum_required(VERSION 3.18)
project(webos-native LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

include(WebOSTarget)
include(WebOSPackage)
include(Assets)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# Compatible with what the TV ships.
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
    set_target_properties(TARGET_NAME PROPERTIES LINK_FLAGS_RELEASE -s)
endif ()

add_compile_options(-Wall -Wextra -Wno-unused-parameter)

add_link_options($<$<CONFIG:Release>:-s>)

# Allow FPU usage within the app, while ABI stays soft-float.
if (TARGET_WEBOS AND TARGET_WEBOS_ARCH STREQUAL "arm")
    add_compile_options(-mcpu=cortex-a55 -mfpu=neon-vfpv4 -mfloat-abi=softfp)
endif ()

# Prefer bundled FFmpeg for compatibility reasons.
if (TARGET_WEBOS)
    set(_ffmpeg_default "${WEBOS_SDK}/arm-webos-linux-gnueabi/sysroot/usr/local/ffmpeg")
else ()
    set(_ffmpeg_default "${CMAKE_SOURCE_DIR}/build/ffmpeg-host")
endif ()
set(FFMPEG_ROOT "${_ffmpeg_default}" CACHE PATH "FFmpeg prefix")
set(FFMPEG_SONAMES libavformat.so.63 libavcodec.so.63 libavutil.so.61 libswresample.so.7
        libmbedtls.so.21 libmbedx509.so.7 libmbedcrypto.so.16)

# libass, and the two libraries it will not build without. The TV ships FreeType but
# neither of these; tools/build-libass.sh puts them here.
if (TARGET_WEBOS)
    set(_libass_default "${WEBOS_SDK}/arm-webos-linux-gnueabi/sysroot/usr/local/libass")
else ()
    set(_libass_default "${CMAKE_SOURCE_DIR}/build/libass-host")
endif ()
set(LIBASS_ROOT "${_libass_default}" CACHE PATH "libass prefix")
set(LIBASS_SONAMES libass.so.9 libfribidi.so.0 libharfbuzz.so.0)

add_subdirectory(src)
if (NOT TARGET_WEBOS)
    enable_testing()
    add_subdirectory(tests)
endif ()
