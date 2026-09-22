# Turns any file into a C source + header pair holding its bytes.
#
# Invoked as: cmake -DINPUT=<file> -DOUTPUT_C=<file.c> -DOUTPUT_H=<file.h> -DSYMBOL=<name>
#             -P EmbedFile.cmake
#
# Zig had @embedFile; this is the C equivalent, and it is a script rather than a
# configure_file so the byte array is regenerated when the asset changes.

file(READ "${INPUT}" _hex HEX)
string(LENGTH "${_hex}" _len)
math(EXPR _bytes "${_len} / 2")

set(_body "")
set(_i 0)
set(_col 0)
while (_i LESS _len)
    string(SUBSTRING "${_hex}" ${_i} 2 _byte)
    string(APPEND _body "0x${_byte},")
    math(EXPR _col "${_col} + 1")
    if (_col EQUAL 16)
        string(APPEND _body "\n")
        set(_col 0)
    endif ()
    math(EXPR _i "${_i} + 2")
endwhile ()

file(WRITE "${OUTPUT_H}"
        "/* Generated from ${INPUT}. Do not edit. */\n"
        "#pragma once\n#include <stddef.h>\n"
        "extern const unsigned char ${SYMBOL}[];\n"
        "extern const size_t ${SYMBOL}_len;\n")
file(WRITE "${OUTPUT_C}"
        "/* Generated from ${INPUT}. Do not edit. */\n"
        "#include <stddef.h>\n"
        "const unsigned char ${SYMBOL}[] = {\n${_body}0x00};\n"
        "const size_t ${SYMBOL}_len = ${_bytes};\n")
