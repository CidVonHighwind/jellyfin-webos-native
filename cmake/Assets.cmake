# Compiled shaders and binary assets, turned into C arrays.
#
#   webos_embed(<target> SYMBOL <name> FILE <path>)
#   webos_add_shader(<target> SYMBOL <name> SRC <x.slang> ENTRY <fn> STAGE <vertex|fragment>)
#
# Slang only emits desktop GLSL - there is no ESSL profile - so the header is rewritten:
# `#version 450` and the two `layout(row_major)` defaults are GLSL 4.x-only, and ES insists
# on explicit default precision. The body needs no changes as long as the shaders avoid the
# constructs Slang lowers to Vulkan-only GLSL; see docs/opengl.md.

set(WEBOS_ASSETS_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(_webos_embed_command TARGET SYMBOL INPUT)
    set(_gen "${CMAKE_CURRENT_BINARY_DIR}/generated")
    set(_c "${_gen}/${SYMBOL}.c")
    set(_h "${_gen}/${SYMBOL}.h")
    add_custom_command(OUTPUT "${_c}" "${_h}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${_gen}"
            COMMAND "${CMAKE_COMMAND}" "-DINPUT=${INPUT}" "-DOUTPUT_C=${_c}" "-DOUTPUT_H=${_h}"
            "-DSYMBOL=${SYMBOL}" -P "${WEBOS_ASSETS_MODULE_DIR}/EmbedFile.cmake"
            DEPENDS "${INPUT}"
            COMMENT "Embedding ${SYMBOL}"
            VERBATIM)
    target_sources(${TARGET} PRIVATE "${_c}" "${_h}")
    target_include_directories(${TARGET} PRIVATE "${_gen}")
endfunction()

function(webos_embed TARGET)
    cmake_parse_arguments(E "" "SYMBOL;FILE" "" ${ARGN})
    _webos_embed_command(${TARGET} "${E_SYMBOL}" "${E_FILE}")
endfunction()

function(webos_add_shader TARGET)
    cmake_parse_arguments(S "" "SYMBOL;SRC;ENTRY;STAGE" "" ${ARGN})
    if (S_STAGE STREQUAL "vertex")
        set(_short vert)
    else ()
        set(_short frag)
    endif ()
    set(_glsl "${CMAKE_CURRENT_BINARY_DIR}/generated/${S_SYMBOL}.glsl")
    add_custom_command(OUTPUT "${_glsl}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
            COMMAND "${CMAKE_COMMAND}" -E env "JF_GLSL_VERSION=${JF_GLSL_VERSION}"
            sh "${WEBOS_ASSETS_MODULE_DIR}/slangc.sh"
            "${S_SRC}" "${S_STAGE}" "${S_ENTRY}" "${_short}" "${_glsl}"
            DEPENDS "${S_SRC}" "${WEBOS_ASSETS_MODULE_DIR}/slangc.sh"
            COMMENT "slangc ${S_ENTRY}"
            VERBATIM)
    _webos_embed_command(${TARGET} "${S_SYMBOL}" "${_glsl}")
endfunction()
