# Build-time guard: the sample elementary streams are not committed to git, so a fresh
# clone can compile but cannot be packaged until they exist. Fail here with something
# actionable rather than letting ares-package produce an ipk that crashes on the TV.
#
# Invoked as: cmake -DMEDIA_FILES=<;-separated> -P CheckSampleMedia.cmake

set(_missing "")
foreach (_file IN LISTS MEDIA_FILES)
    if (NOT EXISTS "${_file}")
        list(APPEND _missing "${_file}")
    endif ()
endforeach ()

if (_missing)
    string(REPLACE ";" "\n  " _missing_pretty "${_missing}")
    message(FATAL_ERROR
            "Sample media is missing:\n  ${_missing_pretty}\n\n"
            "Generate it from any video file with:\n"
            "  assets/make-sample.sh <input-video>\n\n"
            "or point the build at streams you already have:\n"
            "  cmake -B build -DSAMPLE_MEDIA_DIR=/path/to/streams ...\n")
endif ()
