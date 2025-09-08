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

set(FETCHCONTENT_QUIET FALSE CACHE BOOL "Suppress output from FetchContent" FORCE)

# Use system VLC installation
set(VLC_INSTALL_DIR "C:/Program Files/VideoLAN/VLC" CACHE PATH "Path to VLC installation")

# Download VLC headers from the official repository
include(FetchContent)
FetchContent_Declare(
    vlc_headers
    GIT_REPOSITORY https://code.videolan.org/videolan/vlc.git
    GIT_TAG 3.0.21
    GIT_PROGRESS TRUE
    GIT_DEPTH 1
)

FetchContent_MakeAvailable(vlc_headers)

if (DOWNLOAD_VLC_BINARIES)
    message(STATUS "Downloading VLC Windows binaries...")
    # Download VLC Windows binaries
    FetchContent_Declare(
        vlc_binaries
        URL https://download.videolan.org/vlc/3.0.21/win64/vlc-3.0.21-win64.zip
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(vlc_binaries)
endif()

# Set VLC directories
set(VLC_INCLUDE_DIR ${vlc_headers_SOURCE_DIR}/include)
set(VLC_BIN_DIR ${VLC_INSTALL_DIR})

# Create import library from system VLC installation
# First, check if VLC is installed
if(NOT EXISTS "${VLC_INSTALL_DIR}/libvlc.dll")
    message(FATAL_ERROR "VLC not found at ${VLC_INSTALL_DIR}. Please install VLC or set VLC_INSTALL_DIR to correct path.")
endif()

# Debug: Print the values of CMAKE_DLLTOOL and GENDEF_EXECUTABLE
message(STATUS "CMAKE_DLLTOOL is set to: ${CMAKE_DLLTOOL}")
message(STATUS "GENDEF_EXECUTABLE is set to: ${GENDEF_EXECUTABLE}")

# Create import library from system libvlc.dll using gendef and dlltool
# Check if GENDEF_EXECUTABLE was set in preset, otherwise find it
if(NOT GENDEF_EXECUTABLE)
    find_program(GENDEF_EXECUTABLE gendef)
endif()

if(NOT GENDEF_EXECUTABLE)
    message(WARNING "gendef not found. Creating import library from manual def file.")
    # Create manual def file if gendef is not available
    file(WRITE ${CMAKE_BINARY_DIR}/libvlc.def "EXPORTS\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_new\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_release\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_errmsg\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_new_path\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_release\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_get_meta\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_new\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_release\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_media\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_play\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_pause\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_stop\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_is_playing\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_time\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_time\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_get_length\n")
    file(APPEND ${CMAKE_BINARY_DIR}/libvlc.def "libvlc_media_player_set_hwnd\n")
else()
    message(STATUS "Using gendef to extract exports from system DLL")
    # Use gendef to extract exports from system DLL
    add_custom_command(
        OUTPUT ${CMAKE_BINARY_DIR}/libvlc.def
        COMMAND ${GENDEF_EXECUTABLE} - "${VLC_INSTALL_DIR}/libvlc.dll" > ${CMAKE_BINARY_DIR}/libvlc.def
        DEPENDS "${VLC_INSTALL_DIR}/libvlc.dll"
        COMMENT "Extracting exports from system libvlc.dll"
    )
endif()

# Create the import library using dlltool
add_custom_command(
    OUTPUT ${CMAKE_BINARY_DIR}/libvlc.lib
    COMMAND ${CMAKE_DLLTOOL} -d ${CMAKE_BINARY_DIR}/libvlc.def -l ${CMAKE_BINARY_DIR}/libvlc.lib
    DEPENDS ${CMAKE_BINARY_DIR}/libvlc.def
    COMMENT "Creating libvlc import library from system installation"
)
add_custom_target(libvlc_import DEPENDS ${CMAKE_BINARY_DIR}/libvlc.lib)

# Define the executable with modular source files
add_executable(vlc_status_server 
    vlc_status_server.c
    src/vlc_player.c
    src/network.c
    src/ui.c
    src/utils.c
    src/http_server.c
)

# Make executable depend on import library
add_dependencies(vlc_status_server libvlc_import)

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

# Link against Windows libraries and VLC import library
target_link_libraries(vlc_status_server
    ${CMAKE_BINARY_DIR}/libvlc.lib
    ws2_32
    comctl32
    comdlg32
    user32
    gdi32
    shell32
    ole32
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
