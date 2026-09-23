# One binary of plain asserts over the parts that have no device in them. No framework:
# these exist so a wrong branch fails a build, not to describe the code.
add_executable(jf-tests tests.c)
target_link_libraries(jf-tests PRIVATE jf-portable)
if (TARGET jf-demux)
    target_link_libraries(jf-tests PRIVATE jf-demux)
    target_compile_definitions(jf-tests PRIVATE JF_HAVE_DEMUX=1)
endif ()
add_test(NAME jf-tests COMMAND jf-tests)
