# Locates the openlgtv buildroot NDK and defers to the toolchain file it ships.
#
#   cmake --preset webos                       # /opt/arm-webos-linux-gnueabi_sdk-buildroot
#   WEBOS_SDK=/path/to/ndk cmake --preset webos
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=cmake/webos-toolchain.cmake -DWEBOS_SDK=/path
#
# The NDK's own toolchainfile.cmake is generated and must not be edited, and CMake presets
# have no "environment variable or this default" form - so the choice is made here.
if (NOT DEFINED WEBOS_SDK)
    set(WEBOS_SDK "$ENV{WEBOS_SDK}")
endif ()
if (NOT WEBOS_SDK)
    set(WEBOS_SDK "/opt/arm-webos-linux-gnueabi_sdk-buildroot")
endif ()
if (NOT EXISTS "${WEBOS_SDK}/share/buildroot/toolchainfile.cmake")
    message(FATAL_ERROR
            "No webOS NDK at ${WEBOS_SDK}.\n"
            "Install the openlgtv buildroot SDK, or point WEBOS_SDK at it.")
endif ()
set(WEBOS_SDK "${WEBOS_SDK}" CACHE PATH "openlgtv buildroot NDK" FORCE)
include("${WEBOS_SDK}/share/buildroot/toolchainfile.cmake")
