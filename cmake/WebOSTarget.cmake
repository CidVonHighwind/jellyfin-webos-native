# Detects whether we are cross-compiling for webOS, and which arch.
#
# Sets in the caller's scope:
#   TARGET_WEBOS       - ON when the C compiler targets *-webos-linux-*
#   TARGET_WEBOS_ARCH  - "arm" or "i686"/"i586"..., matching what ares-package expects
#
# There is no toolchain file in this repo on purpose - use the one shipped with the
# openlgtv buildroot NDK:
#
#   cmake -B build -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=/opt/arm-webos-linux-gnueabi_sdk-buildroot/share/buildroot/toolchainfile.cmake

get_filename_component(_webos_cc_name "${CMAKE_C_COMPILER}" NAME)

if (_webos_cc_name MATCHES "^arm-webos-linux-gnueabi-")
    set(TARGET_WEBOS ON)
    set(TARGET_WEBOS_ARCH "arm")
elseif (_webos_cc_name MATCHES "^(i[3-6]86)-webos-linux-gnu-")
    set(TARGET_WEBOS ON)
    set(TARGET_WEBOS_ARCH "${CMAKE_MATCH_1}")
else ()
    set(TARGET_WEBOS OFF)
    set(TARGET_WEBOS_ARCH "")
endif ()

unset(_webos_cc_name)

if (TARGET_WEBOS)
    message(STATUS "Target: webOS (${TARGET_WEBOS_ARCH})")
else ()
    message(STATUS "Target: host - everything that does not need the TV's own libraries")
endif ()
