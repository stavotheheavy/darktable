include_directories(${DARKTABLE_BINDIR})

find_package(PkgConfig REQUIRED)
pkg_check_modules(JSON_GLIB REQUIRED json-glib-1.0)

# libdtbridge: a plain-C face over libdarktable's headless engine for a native
# front end (the Swift app under macos/). it reuses the MCP server's bridge
# translation unit so there is one place that talks to darktable internals.
add_library(dtbridge SHARED
  dtb.c
  ../mcp/dt_bridge.c)

set_target_properties(dtbridge PROPERTIES LINKER_LANGUAGE C)

target_include_directories(dtbridge PRIVATE ${JSON_GLIB_INCLUDE_DIRS})
target_link_directories(dtbridge PRIVATE ${JSON_GLIB_LIBRARY_DIRS})
target_link_libraries(dtbridge lib_darktable whereami ${JSON_GLIB_LIBRARIES})

set_target_properties(dtbridge
                      PROPERTIES
                      INSTALL_RPATH "${RPATH_ORIGIN}"
                      LIBRARY_OUTPUT_DIRECTORY ${DARKTABLE_LIBDIR})

install(TARGETS dtbridge DESTINATION ${CMAKE_INSTALL_LIBDIR}/darktable COMPONENT DTApplication)
