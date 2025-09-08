cmake_minimum_required(VERSION 3.10)
project(vlc_status_server VERSION 1.0.0 LANGUAGES C)

# Set C standard to C17
set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Force Windows x64 cross-compilation with MinGW
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Set default build type to Release if not specified
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build." FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Release" "MinSizeRel" "RelWithDebInfo")
endif()

# Download VLC headers from the official repository
include(FetchContent)
FetchContent_Declare(
    vlc_headers
    GIT_REPOSITORY https://code.videolan.org/videolan/vlc.git
    GIT_TAG 3.0.21
)

# Download VLC Windows binaries
FetchContent_Declare(
    vlc_binaries
    URL https://download.videolan.org/vlc/3.0.21/win64/vlc-3.0.21-win64.zip
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)

FetchContent_MakeAvailable(vlc_headers vlc_binaries)

# Set VLC directories
set(VLC_INCLUDE_DIR ${vlc_headers_SOURCE_DIR}/include)
set(VLC_BIN_DIR ${vlc_binaries_SOURCE_DIR})

# Create import library from def file using dlltool
add_custom_command(
    OUTPUT ${CMAKE_BINARY_DIR}/libvlc.lib
    COMMAND ${CMAKE_DLLTOOL} -d ${CMAKE_BINARY_DIR}/libvlc.def -l ${CMAKE_BINARY_DIR}/libvlc.lib
    DEPENDS ${CMAKE_BINARY_DIR}/libvlc.def
    COMMENT "Creating libvlc import library"
)
add_custom_target(libvlc_import DEPENDS ${CMAKE_BINARY_DIR}/libvlc.lib)

# Create import library for libvlc.dll (to be found at runtime on Windows)
# We'll link against these but they resolve at runtime
file(WRITE ${CMAKE_BINARY_DIR}/libvlc.def "EXPORTS\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_new\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_release\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_errmsg\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_new_path\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_release\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_get_meta\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_new\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_new_from_media\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_release\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_media\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_play\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_pause\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_stop\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_is_playing\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_time\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_time\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_length\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_media\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_hwnd\n")
file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_hwnd\n")

# Define the executable
add_executable(vlc_status_server vlc_status_server.c)
# add_executable(vlc_status_server vlc_dll_test.c)

# Make executable depend on import library
add_dependencies(vlc_status_server libvlc_import)  # copy_vlc_runtime)

# Include VLC headers
target_include_directories(vlc_status_server PRIVATE ${VLC_INCLUDE_DIR})

# MinGW-specific compiler flags
target_compile_options(vlc_status_server PRIVATE -Wall -Wextra -Wpedantic)

# Windows-specific definitions and libraries
target_compile_definitions(vlc_status_server PRIVATE
    _WIN32_WINNT=0x0601
    WIN32_LEAN_AND_MEAN
    _GNU_SOURCE
)

# Link against Windows libraries only (dynamic loading for VLC)
target_link_libraries(vlc_status_server
    ws2_32
    m
)

# Set output directory
set_target_properties(vlc_status_server PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

# Windows-specific: Force console subsystem
set_target_properties(vlc_status_server PROPERTIES
    WIN32_EXECUTABLE FALSE
)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,--subsystem,console")

# Installation rules
install(TARGETS vlc_status_server
    RUNTIME DESTINATION bin
)

# # Add a custom target to copy VLC DLLs for testing (optional)
# add_custom_target(copy_vlc_dlls
#     COMMAND ${CMAKE_COMMAND} -E echo "To copy VLC DLLs for testing, run:"
#     COMMAND ${CMAKE_COMMAND} -E echo "copy \"C:\\Program Files\\VideoLAN\\VLC\\libvlc.dll\" \"${CMAKE_BINARY_DIR}/bin/\""
#     COMMAND ${CMAKE_COMMAND} -E echo "copy \"C:\\Program Files\\VideoLAN\\VLC\\libvlccore.dll\" \"${CMAKE_BINARY_DIR}/bin/\""
#     COMMAND ${CMAKE_COMMAND} -E echo "xcopy \"C:\\Program Files\\VideoLAN\\VLC\\plugins\" \"${CMAKE_BINARY_DIR}/bin/plugins\" /E /I"
#     VERBATIM
# )

# # Copy VLC runtime files automatically during build
# add_custom_target(copy_vlc_runtime ALL
#     COMMAND ${CMAKE_COMMAND} -E copy_if_different
#         "${VLC_BIN_DIR}/libvlc.dll"
#         "${CMAKE_BINARY_DIR}/bin/"
#     COMMAND ${CMAKE_COMMAND} -E copy_if_different
#         "${VLC_BIN_DIR}/libvlccore.dll"
#         "${CMAKE_BINARY_DIR}/bin/"
#     COMMAND ${CMAKE_COMMAND} -E copy_if_different
#         "${VLC_BIN_DIR}/axvlc.dll"
#         "${CMAKE_BINARY_DIR}/bin/"
#     COMMAND ${CMAKE_COMMAND} -E copy_if_different
#         "${VLC_BIN_DIR}/npvlc.dll"
#         "${CMAKE_BINARY_DIR}/bin/"
#     COMMAND ${CMAKE_COMMAND} -E copy_directory
#         "${VLC_BIN_DIR}/plugins"
#         "${CMAKE_BINARY_DIR}/bin/plugins"
#     COMMENT "Copying VLC runtime files to output directory"
#     VERBATIM
# )

# # Create Windows package
# set(CPACK_PACKAGE_NAME "VLC Status Server")
# set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
# set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Multicast server for VLC playback status")
# set(CPACK_PACKAGE_VENDOR "VLC Status Broadcaster")
# set(CPACK_GENERATOR "ZIP")

# include(CPack)
