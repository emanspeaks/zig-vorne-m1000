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

# Define the executable
add_executable(vlc_status_server vlc_status_server.c)

# MinGW-specific compiler flags
target_compile_options(vlc_status_server PRIVATE -Wall -Wextra -Wpedantic)

# Windows-specific definitions and libraries
target_compile_definitions(vlc_status_server PRIVATE
    _WIN32_WINNT=0x0601
    WIN32_LEAN_AND_MEAN
)
target_link_libraries(vlc_status_server ws2_32)

# Set output directory
set_target_properties(vlc_status_server PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

# Installation rules
install(TARGETS vlc_status_server
    RUNTIME DESTINATION bin
)

# Create Windows package
set(CPACK_PACKAGE_NAME "VLC Status Server")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Multicast server for VLC playback status")
set(CPACK_PACKAGE_VENDOR "VLC Status Broadcaster")
set(CPACK_GENERATOR "ZIP")

include(CPack)
